import numpy as np
import librosa
import math
from scipy.spatial.distance import pdist, squareform
from dataclasses import dataclass
from typing import List, Tuple, Dict

# Exact 64-bit float representation of the Golden Ratio
PHI = (1.0 + math.sqrt(5.0)) / 2.0 
MAX_PERCEPTUAL_LATENCY_SEC = 0.020

@dataclass
class TopologicalState:
    time_sec: float
    theta: float      
    z_force: float    
    r_semantic: float 
    is_keyframe: bool 

class TopologicalAudioOracle:
    """
    Python Reference Engine for .bee Topological Audio Indexing.
    Executes dynamic feature extraction and Polymerase proofreading.
    """
    
    def __init__(self, sr: int = 44100, hop_length: int = 512, bpm: float = 120.0):
        self.sr = sr
        self.hop_length = hop_length
        self.bpm = bpm
        self.t_bar = (60.0 / self.bpm) * 4.0 
        self.hop_duration_sec = self.hop_length / self.sr

    def _calculate_dynamic_thresholds(self, r_norm: np.ndarray) -> Tuple[float, float]:
        """
        Derives the track-specific drift rate and proofreading threshold 
        based on the statistical volatility of the semantic radius.
        """
        # Calculate instantaneous semantic velocity (dr/dt)
        dr = np.diff(r_norm)
        dr_dt = dr / self.hop_duration_sec
        
        # Track volatility is the standard deviation of the semantic velocity
        track_volatility = np.std(dr_dt)
        
        # Bound volatility to human perceptual integration limits (20ms)
        drift_rate_est = track_volatility * MAX_PERCEPTUAL_LATENCY_SEC
        
        # Apply Golden Ratio for Proofreading Threshold
        # Enforce a 1e-6 floor to prevent division-by-zero during absolute silence
        drift_rate_est = max(drift_rate_est, 1e-6)
        proofreading_threshold = drift_rate_est * PHI
        
        return drift_rate_est, proofreading_threshold

    def extract_manifold_coordinates(self, y: np.ndarray) -> Tuple[List[TopologicalState], float]:
        """
        Maps standard PCM data to the (r, theta, z) coordinate space 
        and derives dynamic error thresholds.
        """
        # Feature Extraction
        rms = librosa.feature.rms(y=y, hop_length=self.hop_length)[0]
        spectral_centroid = librosa.feature.spectral_centroid(y=y, sr=self.sr, hop_length=self.hop_length)[0]
        
        # Normalization
        rms_norm = rms / (np.max(rms) + 1e-9)
        r_norm = spectral_centroid / (np.max(spectral_centroid) + 1e-9)
        
        # Dynamic Threshold Calculation
        _, dynamic_tau = self._calculate_dynamic_thresholds(r_norm)
        
        times = librosa.frames_to_time(np.arange(len(rms)), sr=self.sr, hop_length=self.hop_length)
        
        states = []
        z_integrated = 0.0
        
        for i, t in enumerate(times):
            theta = (2 * np.pi * (t / self.t_bar)) % (2 * np.pi)
            
            if i > 0:
                dt = t - times[i-1]
                z_integrated += rms_norm[i] * dt
                
            r_semantic = r_norm[i]
            
            states.append(TopologicalState(
                time_sec=t,
                theta=theta,
                z_force=z_integrated,
                r_semantic=r_semantic,
                is_keyframe=False
            ))
            
        return states, dynamic_tau

    def apply_polymerase_proofreading(self, states: List[TopologicalState], tau: float) -> List[TopologicalState]:
        """
        Executes drift excision using the dynamically calculated threshold (tau).
        """
        if not states:
            return states

        states[0].is_keyframe = True
        accumulated_drift = 0.0
        
        for i in range(1, len(states)):
            truth = states[i]
            predicted_r = states[i-1].r_semantic 
            
            # Integrate geometric error
            dt = truth.time_sec - states[i-1].time_sec
            instant_error = abs(truth.r_semantic - predicted_r)
            accumulated_drift += instant_error * dt
            
            # Evaluate against dynamic bound
            if accumulated_drift >= tau:
                states[i].is_keyframe = True
                accumulated_drift = 0.0 
                
        return states

    def process_audio(self, filepath: str) -> Dict:
        """
        Execution Pipeline.
        """
        y, _ = librosa.load(filepath, sr=self.sr)
        
        # 1. Transform Space & Calculate Constraints
        raw_manifold, dynamic_tau = self.extract_manifold_coordinates(y)
        
        # 2. Error Correction
        proofread_manifold = self.apply_polymerase_proofreading(raw_manifold, dynamic_tau)
        
        # Calculate statistics
        keyframe_count = sum(1 for s in proofread_manifold if s.is_keyframe)
        total_frames = len(proofread_manifold)
        compression_ratio = total_frames / max(1, keyframe_count)
        
        return {
            "manifold": proofread_manifold,
            "statistics": {
                "total_frames": total_frames,
                "keyframes_injected": keyframe_count,
                "theoretical_compression_ratio": compression_ratio,
                "dynamic_proofreading_threshold": dynamic_tau
            }
        }