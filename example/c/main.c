#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/cdefs.h>
#include "funnel.h"

// simple example structure
// we pack it to calculate size easier
struct __attribute__((packed)) data {
  uint8_t age;
  char grade;
};

// Define our marshal method for the writer.
int data_marshal(void* obj, uint8_t* buffer, size_t len) {
  struct data *local = (struct data*)obj;
  printf("marshal data: age=%d, grade=%c\n", local->age, local->grade);
  buffer[0] = local->age;
  buffer[1] = local->grade;
  return 0;
}

// Define our unmarshal method for the reader
void* data_unmarshal(uint8_t* buffer) {
  struct data *local = malloc(sizeof(struct data));
  local->age = buffer[0];
  local->grade = (char)buffer[1];
  return local;
}

// Define our method to return the size of our data after marshalled.
size_t data_size() {
  return sizeof(struct data);
}

// Define our callback to be called within the reader
void callback(void* obj) {
  struct data *local = (struct data*)obj;
  printf("read data: age=%d, grade=%c\n", local->age, local->grade);
  free(local);
}

int main(int argc, char **argv) {
  // create a funnel structure
  struct funnel_t fun;
  // create our event marshaller with our defined functions
  struct event_marshaller_t marshaller = {
    .marshal = data_marshal,
    .unmarshal = data_unmarshal,
    .size = data_size,
  };
  // initialize
  int ret = funnel_init(&fun, marshaller);
  if (ret != 0) {
    printf("funnel failed to initialize: %d\n", ret);
    exit(1);
  }

  // create our data and event
  struct data obj = {
   .age = 31,
   .grade = 'A',
  };
  struct event_t e = {
    .payload = &obj,
  };

  // just to show our original values
  printf("init data: age=%d, grade=%c\n", obj.age, obj.grade);

  // write data
  struct funnel_result result = funnel_write(&fun, e);
  if (result.result != SUCCESS) {
    printf("funnel write failed: %d\n", result.result);
    exit(1);
  }

  // read data with our callback
  result = funnel_read(&fun, callback);
  if (result.result != SUCCESS) {
    printf("funnel read failed: %d\n", result.result);
    exit(1);
  }

  // free funnel internals
  funnel_free(&fun);
}
