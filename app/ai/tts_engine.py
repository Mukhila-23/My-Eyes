import logging
import os
import uuid

from gtts import gTTS

logger = logging.getLogger("myeyes.tts")


AUDIO_FOLDER = "app/audio"

# Per-companion gTTS voice. gTTS selects an accent through Google's top-level
# domain, so "alex" and "maya" get audibly different voices: Alex is the
# en-GB variant, Maya the en-US one. `slow` gives Maya a slightly gentler
# delivery, which is what makes the two feel like different people rather
# than the same recording played at the same speed.
#
# Flutter applies its own on-device pitch/voice per companion on top of this;
# this mapping exists so the MP3s the backend generates (and therefore played
# through the module results) match the companion the user selected.
COMPANION_VOICES = {
    "alex": {"tld": "en-GB", "slow": False},
    "maya": {"tld": "en-US", "slow": True},
}

DEFAULT_VOICE = {"tld": "en-US", "slow": False}


def resolve_voice(companion: str | None) -> dict:
    """Pick the gTTS voice for a companion id, defaulting safely."""
    if not companion:
        return DEFAULT_VOICE
    return COMPANION_VOICES.get(str(companion).strip().lower(), DEFAULT_VOICE)


def generate_speech(text: str | None, companion: str | None = None) -> str:
    """
    Convert text to speech and save it as an MP3 file.
    Returns the URL of the generated audio.

    `companion` selects the voice ("alex" / "maya"). It is optional so every
    existing caller keeps working unchanged.
    """

    # gTTS asserts on an empty string. Backend audio is optional because the
    # Flutter client speaks the result itself, so an empty/external failure
    # must never turn a normal scan into a 500.
    if not text or not text.strip():
        return ""

    # Create audio folder if it doesn't exist
    os.makedirs(AUDIO_FOLDER, exist_ok=True)

    # Generate unique filename
    filename = f"{uuid.uuid4()}.mp3"

    file_path = os.path.join(AUDIO_FOLDER, filename)

    voice = resolve_voice(companion)

    # Generate speech
    try:
        tts = gTTS(
            text=text.strip(),
            lang="en",
            tld=voice["tld"],
            slow=voice["slow"],
        )
        tts.save(file_path)
    except Exception:
        # gTTS reaches Google's servers. If that fails, return no audio: the
        # phone still speaks the same text with its own companion voice.
        logger.exception("gTTS generation failed; returning no audio url")
        return ""

    # Return the URL
    return f"/audio/{filename}"
