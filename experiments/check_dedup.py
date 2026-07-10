import sys
import os

# Force Python to look in the main sonoFaig folder so imports work perfectly
parent_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, parent_dir)

from beehive.audio import load_audio, content_hash

def check_dedup():
    # Pointing to the specific track you uploaded
    path = "experiments/recon/15928052_Liverpool Street In The Rain_(Original Mix)/15928052_Liverpool Street In The Rain_(Original Mix)_ORIGINAL_75s.wav"
    bpm = 128.0  # Standard House BPM for this track
    B = 4
    
    print(f"Loading track and slicing by Bar (BPM: {bpm})...")
    y, sr = load_audio(path, mono=True)
    
    # Calculate how many audio samples make up exactly one musical bar
    bar_samples = int(round(sr * 60.0 * B / bpm))
    num_bars = len(y) // bar_samples
    
    loop_pool = set()
    
    # Slice the track and hash each bar
    for i in range(num_bars):
        start = i * bar_samples
        end = start + bar_samples
        
        # Use your updated content_hash that supports slicing!
        bar_hash = content_hash(y, (start, end))
        loop_pool.add(bar_hash)
        
    total_bars = num_bars
    unique_bars = len(loop_pool)
    duplicates = total_bars - unique_bars
    dedup_rate = duplicates / total_bars if total_bars > 0 else 0.0
    
    print(f"\n--- Layer 1: Data Deduplication Report ---")
    print(f"Total Bars in track: {total_bars}")
    print(f"Unique Bars (Pool Size): {unique_bars}")
    print(f"Duplicate Bars eliminated: {duplicates}")
    print(f"Total storage saved by .bee index: {dedup_rate:.1%}\n")

if __name__ == "__main__":
    check_dedup()