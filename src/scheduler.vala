/* scheduler.vala
 *
 * Thread-pool scheduler for offloading long-running work from the main loop.
 * Ported from wip/scheduler (commit a433e98f) and adapted to current codebase.
 *
 * Copyright 2026 Sergii Fesenko
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */

/**
 * A task that runs on a worker thread and returns a result of type T.
 */
delegate T Vls.TaskFunc<T> () throws Error;

/**
 * Schedules work to be run on worker threads, yielding the caller
 * until the result is ready.
 */
class Vls.Scheduler {
    private ThreadPool<Vls.Worker> _thread_pool;

    public Scheduler () throws ThreadError {
        _thread_pool = new ThreadPool<Vls.Worker>.with_owned_data (
            worker => worker.run (),
            (int) GLib.get_num_processors (),
            false   // not exclusive — workers are shared
        );
    }

    /**
     * Schedule [task] on a worker thread. The caller is suspended (yielded)
     * until the worker finishes, then resumed on the main loop via Idle.add.
     * If the task throws, the error is re-thrown on the main loop.
     */
    public async T run_async<T> (owned Vls.TaskFunc<T> task, GLib.Cancellable? cancellable = null) throws Error {
        GLib.SourceFunc callback = run_async<T>.callback;
        var worker = new Vls.Worker<T> ((owned) task, (owned) callback, cancellable);
        _thread_pool.add (worker);
        yield;
        if (worker.error != null)
            throw worker.error;
        return worker.result;
    }
}

/**
 * Wraps a TaskFunc for execution on a worker thread.
 * After run(), the result or error is delivered to the main loop
 * via Idle.add(callback).
 */
class Vls.Worker<T> {
    public T? result { get; private set; }
    public Error? error { get; private set; }

    private Vls.TaskFunc<T> _task;
    private GLib.SourceFunc _callback;
    private GLib.Cancellable? _cancellable;

    public Worker (owned Vls.TaskFunc<T> task, owned GLib.SourceFunc callback, GLib.Cancellable? cancellable = null) {
        _task = (owned) task;
        _callback = (owned) callback;
        _cancellable = cancellable;
    }

    /**
     * Executes the task synchronously on the worker thread,
     * then schedules the callback on the main loop.
     */
    public void run () {
        try {
            if (_cancellable != null)
                _cancellable.set_error_if_cancelled ();
            result = _task ();
        } catch (Error e) {
            error = e;
        }
        GLib.Idle.add ((owned) _callback);
    }
}
