import sys
import matplotlib.pyplot as plt
import numpy as np

# Import your existing engine
from beehive.encode import encode_song

def plot_bee_helix(path, bpm):
    print(f"Encoding audio: {path}...")
    
    # Run the song through your existing pipeline
    # (This returns the HelixRecord with derived x, y, z coords)
    record = encode_song(path, bpm=bpm)
    
    # Depending on how HelixRecord is structured in record.py, 
    # we extract the arrays. (Using vars() or direct attribute access)
    try:
        x = record.x
        y = record.y
        z = record.z
        f_mag = record.F_mag
    except AttributeError:
        # Fallback if HelixRecord behaves like a dictionary
        x = record["x"]
        y = record["y"]
        z = record["z"]
        f_mag = record["F_mag"]

    print("Opening 3D interactive chart...")
    
    # Initialize the Matplotlib 3D figure
    fig = plt.figure(figsize=(10, 8))
    ax = fig.add_subplot(111, projection='3d')
    
    # Plot the space curve. We color the points using the F_mag (Musical Force)
    # so high-energy drops appear brightly colored!
    scatter = ax.scatter(x, y, z, c=f_mag, cmap='magma', s=2, alpha=0.8)
    
    # Formatting the visualizer
    ax.set_title(f".bee Topological Audio Index\n{path.split('/')[-1]}", fontweight="bold")
    ax.set_xlabel("X (r * cos θ)")
    ax.set_ylabel("Y (r * sin θ)")
    ax.set_zlabel("Z (Climb / Accumulated Energy)")
    
    # Add a legend/colorbar for the force energy
    cbar = plt.colorbar(scatter, ax=ax, pad=0.1, shrink=0.7)
    cbar.set_label("Musical Force ||F||")
    
    # This command triggers the local pop-up window!
    plt.show()

if __name__ == "__main__":
    # Point this to one of the tracks you uploaded
    song_path = "experiments/recon/15928052_Liverpool Street In The Rain_(Original Mix)/15928052_Liverpool Street In The Rain_(Original Mix)_ORIGINAL_75s.wav"
    
    # Run the visualizer (make sure to match the exact float BPM from your JSONs)
    plot_bee_helix(song_path, bpm=128.0)