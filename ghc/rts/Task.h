/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team 2001-
 *
 * Types + prototypes for functions in Task.cn
 * (RTS subsystem for handling OS tasks).
 *
 * -------------------------------------------------------------------------*/
#ifndef __TASK_H__
#define __TASK_H__
#if defined(RTS_SUPPORTS_THREADS) /* to the end */

/* 
 * Tasks evaluate STG code; the TaskInfo structure collects together
 * misc metadata about a task.
 * 
 */
typedef struct _TaskInfo {
  OSThreadId id;
  double     elapsedtimestart;
  double     mut_time;
  double     mut_etime;
  double     gc_time;
  double     gc_etime;
} TaskInfo;

extern TaskInfo *taskIds;

extern void startTaskManager ( nat maxTasks, void (*taskStart)(void) );
extern void stopTaskManager ( void );

extern void startTask ( void (*taskStart)(void) );
extern nat  getTaskCount( void );

#endif /* RTS_SUPPORTS_THREADS */
#endif /* __TASK_H__ */
