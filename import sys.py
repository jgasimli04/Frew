import sys
import numpy as np
from beehive.audio import load_audio, content_hash

def test_content_hash():
    """Step 1: Verify the generalized content_hash behavior."""
    print("Running Step 1 tests...")
    y = np.random.randn(44100).astype(np.float32)
    
    # 1. Full range equals no-range
    assert content_hash(y) == content_hash(y, (0, len(y))), "Full range hash mismatch!"
    
    # 2. Identical slices hash equal
    assert content_hash(y, (1000, 2000)) == content_hash(y.copy(), (1000, 2000)), "Identical slices failed to match!"
    
    # 3. Different slices hash differently
    assert content_hash(y, (1000, 2000)) != content_hash(y, (2000, 3000)), "Different slices collided!"
    
    print("-> Step 1 passed: content_hash slice logic is exact.\n")


def analyze_song_dedup(path, bpm, B=4):
    """Steps 2, 3, and 4: Segment, build the recall sequence, and report dedup."""
    # Step 2: Loop Segmentation Math
    y, sr = load_audio(path, mono=True)
    
    # omega = 2*pi * bpm / (60*B), one turn = 2*pi
    # length of one bar in seconds = (60 * B) / bpm
    bar_samples = int(round(sr * 60.0 * B / bpm))
    num_bars = len(y) // bar_samples
    
    loop_pool = {}      # hash -> raw PCM samples (for Step 5 later)
    recall_sequence = []
    
    # Step 3: Minimal Recall-Entry Sequence
    for i in range(num_bars):
        start = i * bar_samples
        end = start + bar_samples
        
        # Exact sample matching using the updated content_hash
        bar_hash = content_hash(y, (start, end))
        
        is_new_loop = False
        if bar_hash not in loop_pool:
            loop_pool[bar_hash] = y[start:end].copy()
            is_new_loop = True
            
        # Minimal metadata record for this bar
        recall_entry = {
            "bar_index": i,
            "start_sample": start,
            "length_samples": bar_samples,
            "loop_hash": bar_hash,
            "inline_payload": is_new_loop
        }
        recall_sequence.append(recall_entry)
        
    # Step 4: Report Dedup Rates
    total_bars = len(recall_sequence)
    unique_bars = len(loop_pool)
    duplicates = total_bars - unique_bars
    dedup_rate = duplicates / total_bars if total_bars > 0 else 0.0
    
    print(f"--- Dedup Report: {path.split('/')[-1]} ---")
    print(f"BPM: {bpm} | Bar length: {bar_samples} samples ({bar_samples/sr:.3f}s)")
    print(f"Total Bars: {total_bars}")
    print(f"Unique Bars (Pool Size): {unique_bars}")
    print(f"Duplicate Bars: {duplicates}")
    print(f"Exact Dedup Savings (Layer 1): {dedup_rate:.1%}\n")
    
    return recall_sequence, loop_pool


if __name__ == "__main__":
    test_content_hash()
    
    # To run this, you will need the exact BPM used during encoding.
    # You can read it out of the JSON files in your helichain/records directory.
    
    # Example usage (replace with your actual local paths and JSON-derived BPMs):
    """
    analyze_song_dedup(
        path="../experiments/recon/15928052_Liverpool Street In The Rain_(Original Mix)/15928052_Liverpool Street In The Rain_(Original Mix)_ORIGINAL_75s.wav", 
        bpm=128.0 # Replace with exact float from JSON
    )
    """