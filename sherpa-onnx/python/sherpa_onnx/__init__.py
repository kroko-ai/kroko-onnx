# Re-export names from the native _sherpa_onnx extension. The full list
# reflects everything upstream sherpa-onnx exposes when built with every
# optional feature on (TTS, speaker diarization, denoiser, etc.).
#
# Kroko's distribution builds are slimmer — `SHERPA_ONNX_ENABLE_TTS=OFF`
# in particular drops the OfflineTts* classes from the .pyd — so an
# unconditional `from _sherpa_onnx import OfflineTts...` would crash the
# entire package at import time on those wheels. Instead we walk the
# name list and pull in only what the build actually includes; consumers
# of the streaming recogniser (the supported Kroko surface) get an
# `import kroko_onnx` that always succeeds, and `dir(kroko_onnx)` shows
# exactly which optional features were compiled in.
import _sherpa_onnx as _native

_OPTIONAL_NATIVE_NAMES = (
    "Alsa",
    "AudioEvent",
    "AudioTagging",
    "AudioTaggingConfig",
    "AudioTaggingModelConfig",
    "CircularBuffer",
    "DenoisedAudio",
    "FastClustering",
    "FastClusteringConfig",
    "FeatureExtractorConfig",
    "HomophoneReplacerConfig",
    "OfflineCanaryModelConfig",
    "OfflineCtcFstDecoderConfig",
    "OfflineDolphinModelConfig",
    "OfflineFireRedAsrModelConfig",
    "OfflineLMConfig",
    "OfflineModelConfig",
    "OfflineMoonshineModelConfig",
    "OfflineNemoEncDecCtcModelConfig",
    "OfflineParaformerModelConfig",
    "OfflinePunctuation",
    "OfflinePunctuationConfig",
    "OfflinePunctuationModelConfig",
    "OfflineRecognizerConfig",
    "OfflineSenseVoiceModelConfig",
    "OfflineSourceSeparation",
    "OfflineSourceSeparationConfig",
    "OfflineSourceSeparationModelConfig",
    "OfflineSourceSeparationSpleeterModelConfig",
    "OfflineSourceSeparationUvrModelConfig",
    "OfflineSpeakerDiarization",
    "OfflineSpeakerDiarizationConfig",
    "OfflineSpeakerDiarizationResult",
    "OfflineSpeakerDiarizationSegment",
    "OfflineSpeakerSegmentationModelConfig",
    "OfflineSpeakerSegmentationPyannoteModelConfig",
    "OfflineSpeechDenoiser",
    "OfflineSpeechDenoiserConfig",
    "OfflineSpeechDenoiserGtcrnModelConfig",
    "OfflineSpeechDenoiserModelConfig",
    "OfflineStream",
    "OfflineTdnnModelConfig",
    "OfflineTransducerModelConfig",
    "OfflineTts",
    "OfflineTtsConfig",
    "OfflineTtsKittenModelConfig",
    "OfflineTtsKokoroModelConfig",
    "OfflineTtsMatchaModelConfig",
    "OfflineTtsModelConfig",
    "OfflineTtsVitsModelConfig",
    "OfflineWenetCtcModelConfig",
    "OfflineWhisperModelConfig",
    "OfflineZipformerAudioTaggingModelConfig",
    "OfflineZipformerCtcModelConfig",
    "OnlinePunctuation",
    "OnlinePunctuationConfig",
    "OnlinePunctuationModelConfig",
    "OnlineStream",
    "SileroVadModelConfig",
    "SpeakerEmbeddingExtractor",
    "SpeakerEmbeddingExtractorConfig",
    "SpeakerEmbeddingManager",
    "SpeechSegment",
    "SpokenLanguageIdentification",
    "SpokenLanguageIdentificationConfig",
    "SpokenLanguageIdentificationWhisperConfig",
    "TenVadModelConfig",
    "VadModel",
    "VadModelConfig",
    "VoiceActivityDetector",
    "git_date",
    "git_sha1",
    "version",
    "write_wave",
)

for _name in _OPTIONAL_NATIVE_NAMES:
    _obj = getattr(_native, _name, None)
    if _obj is not None:
        globals()[_name] = _obj
del _name, _obj, _native, _OPTIONAL_NATIVE_NAMES

# Wrapper modules. These each `from _sherpa_onnx import …` their own
# subset, so a missing online/offline binding would still surface as an
# ImportError here — but in the Kroko-shipped builds the streaming
# recogniser bindings are always compiled in, so this stays clean.
from .display import Display
from .keyword_spotter import KeywordSpotter
from .offline_recognizer import OfflineRecognizer
from .online_recognizer import OnlineRecognizer
from .utils import text2token
