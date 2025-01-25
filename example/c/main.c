#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/cdefs.h>
#include "funnel.h"

struct __attribute__((packed)) data {
  uint8_t age;
  char grade;
};


int data_marshal(void* obj, uint8_t* buffer, size_t len) {
  struct data *local = (struct data*)obj;
  printf("marshal data: age=%d, grade=%c\n", local->age, local->grade);
  buffer[0] = local->age;
  buffer[1] = local->grade;
  return 0;
}

void* data_unmarshal(uint8_t* buffer) {
  struct data *local = malloc(sizeof(struct data));
  local->age = buffer[0];
  local->grade = (char)buffer[1];
  return local;
}

size_t data_size() {
  return sizeof(struct data);
}

void callback(void* obj) {
  struct data *local = (struct data*)obj;
  printf("read data: age=%d, grade=%c\n", local->age, local->grade);
  free(local);
}

int main(int argc, char **argv) {
  struct funnel_t fun;
  struct event_marshaller_t marshaller = {
    .marshal = data_marshal,
    .unmarshal = data_unmarshal,
    .size = data_size,
  };
  int ret = funnel_init(&fun, marshaller);
  if (ret != 0) {
    printf("funnel failed to initialize: %d\n", ret);
    exit(1);
  }

  struct data obj = {
   .age = 31,
   .grade = 'A',
  };

  struct event_t e = {
    .payload = &obj,
  };

  printf("init data: age=%d, grade=%c\n", obj.age, obj.grade);

  struct funnel_result result = funnel_write(&fun, e);

  if (result.result != SUCCESS) {
    printf("funnel write failed: %d\n", result.result);
    exit(1);
  }

  result = funnel_read(&fun, callback);

  if (result.result != SUCCESS) {
    printf("funnel read failed: %d\n", result.result);
    exit(1);
  }

  funnel_free(&fun);
}
