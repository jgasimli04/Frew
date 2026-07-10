import sys
import os
import numpy as np
import soundfile as sf

parent_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, parent_dir)

from beehive.audio import load_audio, content_hash
from experiments.check_dedup import check_dedup  # Reusing your logic

def build_and_reconstruct():
    path = "experiments/recon/15928052_Liverpool Street In The Rain_(Original Mix)/15928052_Liverpool Street In The Rain_(Original Mix)_ORIGINAL_75s.wav"
    bpm = 128.0
    B = 4
    
    y_original, sr = load_audio(path, mono=True)
    bar_samples = int(round(sr * 60.0 * B / bpm))
    num_bars = len(y_original) // bar_samples
    
    # 1. ENCODE (The .bee Payload Layer)
    pool = {}
    recall_sequence = []
    
    for i in range(num_bars):
        start = i * bar_samples
        end = start + bar_samples
        bar_audio = y_original[start:end]
        
        b_hash = content_hash(y_original, (start, end))
        
        if b_hash not in pool:
            pool[b_hash] = bar_audio.copy()
            
        recall_sequence.append({
            "hash": b_hash,
            "start": start
        })
        
    # 2. DECODE (The Reconstruction)
    print("Reconstructing audio from .bee recall sequence...")
    reconstructed_audio = np.zeros(num_bars * bar_samples, dtype=np.float32)
    
    for entry in recall_sequence:
        b_hash = entry["hash"]
        start = entry["start"]
        end = start + bar_samples
        
        # Pull the audio chunk directly from the hash pool
        reconstructed_audio[start:end] = pool[b_hash]
        
    # 3. VERIFY (Bit-exact match test)
    # We trim original to match the exact bar boundaries we processed
    y_trimmed = y_original[:len(reconstructed_audio)]
    
    is_exact = np.array_equal(y_trimmed, reconstructed_audio)
    
    print(f"\n--- Step 5: Reconstruction Report ---")
    print(f"Bit-for-bit exact match: {is_exact}")
    
    if is_exact:
        out_path = path.replace("_ORIGINAL_", "_BEE_RECONSTRUCTED_")
        sf.write(out_path, reconstructed_audio, sr)
        print(f"Success! Reconstructed audio saved to:\n{out_path}")

if __name__ == "__main__":
    build_and_reconstruct()