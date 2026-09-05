"""Import-light stand-in for decode_audio's waveform contract.

The real decoder returns a mono float32 numpy.ndarray. The offline harness
uses float samples plus source metadata, so it needs no binary dependency;
tests/integration/test_whisper_contract.py exercises the actual ndarray boundary.
"""

from __future__ import annotations

import sys
import wave
from array import array
from dataclasses import dataclass


@dataclass(frozen=True)
class DecodedAudio:
    samples: array
    source: str

    @property
    def shape(self):
        return (len(self.samples),)


def decode_audio(input_file, sampling_rate=16000, split_stereo=False):
    if sampling_rate != 16000 or split_stereo:
        raise ValueError("the harness supports mono 16 kHz only")
    with wave.open(input_file, "rb") as handle:
        if (handle.getnchannels(), handle.getsampwidth(), handle.getframerate()) != (1, 2, 16000):
            raise ValueError("expected mono 16 kHz s16le WAV")
        payload = handle.readframes(handle.getnframes() + 1)
    samples = array("h")
    samples.frombytes(payload[:len(payload) // 2 * 2])
    if sys.byteorder != "little":
        samples.byteswap()
    source = ""
    if payload.startswith(b"FAKEWAV:"):
        source = payload[len(b"FAKEWAV:"):].decode("utf-8").removesuffix("\n")
    return DecodedAudio(array("f", (sample / 32768.0 for sample in samples)), source)
