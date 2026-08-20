#!/usr/bin/env python3
"""Synthesise the notification tones this application uses.

    python3 tool/sound/build.py

# Why these are generated rather than downloaded

A sound file from the internet arrives with a licence, and a licence is a claim
somebody else makes about a file you cannot verify. "CC0" on a download page is
a sentence on a web page, not a property of the bytes, and a messenger whose
whole argument is that it depends on nobody should not ship an asset whose
provenance is a stranger's word.

These are arithmetic. There is nothing to attribute, nothing to pay, nothing to
revoke, and the recipe is in this file, so anybody can rebuild them and check
that the shipped file is what it claims to be.

# What is being made, and why it sounds like this

    assets/sound/message.wav    an arriving message

A notification tone has about four hundred milliseconds to be recognised
without being annoying on the thousandth hearing. What that means in practice:

  * Two short pitches rather than one. A single tone reads as a system beep;
    an interval reads as a voice, and it rises, because an arrival is a
    question rather than a full stop.
  * Pure sine partials with a little of the octave above. A square or a saw
    carries high harmonics that a phone speaker turns into a rattle.
  * An exponential decay with a five millisecond attack. A hard start clicks,
    because the waveform jumps from silence to full amplitude in one sample.
  * Peak at about half of full scale. Notification tones that reach the ceiling
    are the ones people turn off.

48 kHz, 16 bit, mono. Mono because a notification has no stereo image and the
file is half the size; 48 kHz because that is what Android's mixer runs at, so
nothing has to resample it at the moment it is needed.
"""

import math
import os
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RATE = 48000
PEAK = 0.5

# The pitches, in hertz. E5 and A5 are a perfect fourth apart, which is the
# interval a doorbell uses: unambiguous, and it does not imply a key the way a
# major third does, so it does not clash with whatever music is playing.
E5 = 659.25
A5 = 880.00


def tone(freq, seconds, decay):
    """One pitch, with its octave underneath it and an exponential fall."""
    out = []
    attack = int(RATE * 0.005)

    for i in range(int(RATE * seconds)):
        t = i / RATE
        # The octave above at a fifth of the amplitude. It is what stops the
        # sine sounding like a test signal without adding anything harsh.
        wave_value = math.sin(2 * math.pi * freq * t) + \
            0.2 * math.sin(2 * math.pi * freq * 2 * t)
        envelope = math.exp(-decay * t)
        if i < attack:
            envelope *= i / attack
        out.append(wave_value / 1.2 * envelope)

    return out


def sequence(parts):
    """Lay tones out in time, in seconds, and mix where they overlap."""
    # Rounded up rather than truncated. Truncating loses the last sample of
    # whichever tone ends latest, and the mix then writes past the end.
    length = max(int(RATE * at) + len(samples) for at, samples in parts)
    buffer = [0.0] * length

    for at, samples in parts:
        start = int(RATE * at)
        for i, s in enumerate(samples):
            buffer[start + i] += s

    loudest = max(abs(s) for s in buffer) or 1.0
    return [s / loudest * PEAK for s in buffer]


def write(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))
    return os.path.getsize(path)


def main():
    sounds = os.path.join(ROOT, "assets", "sound")

    # Arriving: rising, and the second pitch starts before the first has gone,
    # which is what makes it one gesture rather than two beeps.
    incoming = sequence([
        (0.00, tone(E5, 0.30, 11.0)),
        (0.09, tone(A5, 0.36, 9.0)),
    ])

    # A falling counterpart for an outgoing message was generated here and
    # removed on 19 August 2026: nothing played it. Sending is already confirmed
    # by the message appearing, and a tone for it would be a sound the person
    # who caused it does not need. The recipe is in the history if it is ever
    # wanted.

    for name, samples in [("message", incoming)]:
        path = os.path.join(sounds, f"{name}.wav")
        size = write(path, samples)
        print(f"  assets/sound/{name}.wav   {len(samples) / RATE:.2f}s  {size:,} bytes")

    # Android plays a notification channel's sound from a raw resource, not from
    # the Flutter asset bundle, so the same file is copied where the resource
    # system will find it. The name has to be lowercase with no dashes.
    raw = os.path.join(ROOT, "android", "app", "src", "main", "res", "raw")
    os.makedirs(raw, exist_ok=True)
    with open(os.path.join(sounds, "message.wav"), "rb") as src:
        data = src.read()
    with open(os.path.join(raw, "rotelyx_message.wav"), "wb") as dst:
        dst.write(data)
    print(f"  android/.../res/raw/rotelyx_message.wav   {len(data):,} bytes")


if __name__ == "__main__":
    main()
