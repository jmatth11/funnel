#ifndef FUNNEL_ZIG_H
#define FUNNEL_ZIG_H

#include <stdint.h>
#include <stddef.h>

/**
 * Marshal function type
 */
typedef int(*marshal_func)(void*, uint8_t*, size_t);
/**
 * Unmarshal function type
 */
typedef void*(*unmarshal_func)(uint8_t*);
/**
 * Size function type
 */
typedef size_t (*size_func)();
/**
 * Callback function type
 */
typedef void (*funnel_callback_func)(void*);

/**
 * Funnel enumeration types.
 */
enum funnel_notifs_t {
  // Success.
  SUCCESS=0,
  // Notifying that the operation would have blocked but is busy
  WOULD_BLOCK = 1,
  // The internal pipes are closed.
  CLOSED = 2,
};

/**
 * Base funnel structure.
 */
struct funnel_t {
  void *__internal;
};

/**
 * Event object to send your payload with.
 */
struct event_t {
  void *payload;
};

/**
 * The event marshaller structure containing all the functionality
 * for the funnel object to handle your objects.
 */
struct event_marshaller_t {
  marshal_func marshal;
  unmarshal_func unmarshal;
  size_func size;
};

/**
 * Structure to contain the result of a read or write operation.
 */
struct funnel_result {
  /**
   * Result value, can be a funnel_notifs_t enum or other error int.
   */
  int result;
  /**
   * The length of bytes read/write.
   */
  int len;
};

/**
 * Initialize the funnel structure with the given marshaller values.
 *
 * @param[out] fun The funnel structure.
 * @param[in] marshaller The event marshaller.
 * @return 0 on success, anything else for failure.
 */
int funnel_init(struct funnel_t *fun, struct event_marshaller_t marshaller);

/**
 * Write the given event to the funnel.
 *
 * @param[in] fun The funnel structure.
 * @param[in] e The event data.
 * @return The result. Can be successful, failure, or WOULD_BLOCK.
 */
struct funnel_result funnel_write(struct funnel_t *fun, struct event_t e);

/**
 * Read from the funnel and pass the data to the given callback function.
 *
 * @param[in] fun The funnel structure.
 * @param[in] cb The callback function to handle the data.
 * @return The result. Can be successful, failure, or WOULD_BLOCK.
 */
struct funnel_result funnel_read(struct funnel_t *fun, funnel_callback_func cb);

/**
 * Free the given funnel.
 * This will free internals and close the pipes.
 *
 * @param[in] fun The funnel structure.
 */
void funnel_free(struct funnel_t *fun);

#endif
