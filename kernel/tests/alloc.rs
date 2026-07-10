//! Acceptance #3: `Kernel::step` is allocation-free.
//!
//! A counting global allocator wraps the system allocator. We do all setup
//! (decode, calibrate, build the kernel, warm past the forward-difference edge
//! and the FFT's first call) *before* arming the counter, then arm it across a
//! single `step` and assert zero heap allocations.
//!
//! This lives in its own test binary: a `#[global_allocator]` is process-wide,
//! and keeping it the sole test here means no other test thread can race the
//! `ARMED` flag.

use beehive_kernel::{calibrate, read_wav_mono, Kernel, Params};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

struct Counting;
static ALLOCS: AtomicUsize = AtomicUsize::new(0);
static ARMED: AtomicBool = AtomicBool::new(false);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ARMED.load(Ordering::SeqCst) {
            ALLOCS.fetch_add(1, Ordering::SeqCst);
        }
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if ARMED.load(Ordering::SeqCst) {
            ALLOCS.fetch_add(1, Ordering::SeqCst);
        }
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn wav_path() -> String {
    format!(
        "{}/../recon/506206_Night_(Original Mix)/506206_Night_(Original Mix)_ORIGINAL_75s.wav",
        env!("CARGO_MANIFEST_DIR")
    )
}

#[test]
fn step_is_allocation_free() {
    let (samples, sr) = read_wav_mono(&wav_path()).unwrap();
    let p = Params::reference(sr, 120.0, 5.0);
    let cal = calibrate(&samples, &p);
    let mut kernel = Kernel::new(&p, &cal);

    // Warm up: cross the forward-diff edge (frame 0) and trigger any first-call
    // lazy init inside the FFT, all before we start counting.
    for k in 0..8 {
        let start = k * p.hop;
        let _ = kernel.step(&samples[start..start + p.n_fft]);
    }

    let start = 8 * p.hop;
    let frame = &samples[start..start + p.n_fft];

    ARMED.store(true, Ordering::SeqCst);
    let _tick = kernel.step(frame);
    ARMED.store(false, Ordering::SeqCst);

    let n = ALLOCS.load(Ordering::SeqCst);
    eprintln!("allocations during one step(): {n}");
    assert_eq!(n, 0, "Kernel::step must not allocate on the heap");
}
