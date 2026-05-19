## **Open-source speech recognition built for developers.**
>
> Our engine is fully open-source, and you choose how to deploy models: use our **CC-BY-SA licensed community models** or upgrade to **commercial models** with premium performance. We focus on building **fast, high-quality production models** and providing **examples that take the guesswork out** of integration.

## Demos

### ▶️ Android App
Run speech recognition **natively on your phone** using ONNX Runtime.

### 🌐 Browser (WASM)
Experience transcription **directly in your browser**, no server required.
- [Hugging Face Spaces Demo](https://huggingface.co/spaces/Banafo/Kroko-Streaming-ASR-Wasm)
## Documentation

Full documentation could be found [here](https://docs.kroko.ai/on-premise/#)

## Our Community

Join the Kroko community to learn, share, and contribute:

- 💬 **[Discord](https://discord.gg/JT7wdtnK79)** – chat with developers, ask questions, and share projects.  
- 📢 **[Reddit](https://www.reddit.com/r/kroko_ai/)** – join discussions, showcase your integrations, and follow updates.
- 🤗 **[Hugging Face](https://huggingface.co/Banafo/Kroko-ASR)** – explore our models, try live demos, and contribute feedback.

---

## Table of Contents

1. [Building `kroko-onnx`](#1-building-kroko-onnx)  
   1.1 [Linux (x64 or arm64)](#linux-x64-or-arm64)  
   1.2 [Docker](#docker)  
   1.3 [Python](#python)  

2. [Usage Examples (WebSocket Server)](#2-usage-examples-websocket-server)  
   2.1 [WebSocket Server Format](#websocket-server-format)  
   &nbsp;&nbsp;&nbsp;&nbsp;2.1.1 [Input](#input)  
   &nbsp;&nbsp;&nbsp;&nbsp;2.1.2 [Output](#output)  
   &nbsp;&nbsp;&nbsp;&nbsp;2.1.3 [Output Fields](#output-fields)  

3. [Using `kroko-onnx` from Python](#3-using-kroko-onnx-from-python)  
   3.1 [Import and Create a Recognizer](#import-and-create-a-recognizer)  
   3.2 [Parameter Reference](#parameter-reference)  
   3.3 [Running the Recognizer on Audio Files](#running-the-recognizer-on-audio-files)

---

## 1. Building `kroko-onnx`

### Linux (x64 or arm64)

```bash
git clone https://github.com/orgs/kroko-ai/kroko-onnx
cd kroko-onnx
mkdir build
cd build

# By default, it builds static libraries and uses static link and works only with Kroko free models
cmake -DCMAKE_BUILD_TYPE=Release ..

# To build it with an option to use Kroko Pro models
cmake -DCMAKE_BUILD_TYPE=Release -DKROKO_LICENSE=ON ..

make -j6
```

> ⚠️ **IMPORTANT:** If you build with the license option enabled (`-DKROKO_LICENSE=ON`), and later want to switch back to a license-free build,  
> you **must delete the `build/` directory** first, or explicitly rerun `cmake` with `-DKROKO_LICENSE=OFF` to clear the CMake cache.  
> Otherwise, the license configuration may persist in the build.

After building, you will find the executable `kroko-onnx-online-websocket-server` inside the `bin` directory.

> For GPU builds, refer to:  
> [Sherpa-ONNX GPU Install Guide](https://k2-fsa.github.io/sherpa/onnx/install/linux.html)

---

### Docker

```bash
git clone https://github.com/kroko-ai/kroko-onnx.git
cd kroko-onnx

# For Kroko free models
docker build -t kroko-onnx .

# For Kroko Pro models
docker build -t kroko-onnx --build-arg KROKO_LICENSE=ON .
```

After building, you will find the executable `kroko-onnx-online-websocket-server` and the `kroko-onnx` Python package installed.

---

### Python

```bash
git clone https://github.com/kroko-ai/kroko-onnx
cd kroko-onnx

# For Kroko free models
pip install .

# For Kroko Pro models
KROKO_LICENSE=ON pip install .
```

After installation, you can use the `kroko-onnx` Python package.

---

### macOS (Apple Silicon)

Native arm64 wheel build — no Docker, no cross-compile. Tested on Apple Silicon
(M-series); Intel Macs should work with the same script as long as Homebrew is
installed in `/usr/local`.

```bash
git clone https://github.com/kroko-ai/kroko-onnx
cd kroko-onnx

# Build both pro + free variants (default)
./build_macos.sh

# Or pick one
./build_macos.sh --variant pro
./build_macos.sh --variant free
```

The script auto-installs the build dependencies it needs via Homebrew:
`cmake`, `ninja`, `openssl@3`, `python@3.11`. Python tooling (`pybind11`,
`wheel`, `delocate`) is installed into a venv at `/tmp/kroko-onnx-macos-build/venv`.

#### Outputs

```
release_artifacts/macos/
├── kroko_onnx-<version>-1pro-cp311-cp311-macosx_<host>_arm64.whl
└── kroko_onnx-<version>-1free-cp311-cp311-macosx_<host>_arm64.whl
```

The wheel bundles all non-system dylibs (OpenSSL, onnxruntime) into
`kroko_onnx/.dylibs/` via `delocate-wheel`, so `pip install` works standalone.

> ⚠️ **Deployment target note:** the wheel's `macosx_<host>_arm64` tag matches
> the running macOS version because Homebrew's `openssl@3` dylibs are built
> against the host SDK. For a wheel that installs on older macOS releases,
> run the build on the oldest macOS you support (or use cibuildwheel +
> GitHub Actions macOS runners). No installer is produced on macOS — only the
> Python wheel.

---

### Windows (x86_64)

Windows builds are cross-compiled from a Docker image — no Windows machine required.
A single command produces both the **NSIS installer** (`.exe`) and the **Python wheel**
(`.whl`), and supports two variants:

- **`pro`** — `KROKO_LICENSE=ON`, links OpenSSL (`libssl-3-x64.dll` + `libcrypto-3-x64.dll`).
  Use this for paid/licensed Kroko models.
- **`free`** — `KROKO_LICENSE=OFF`, no license/metrics code, no OpenSSL dependency.
  Use this for the open-source / community workflow.

#### From Linux or macOS (Docker)

```bash
git clone https://github.com/kroko-ai/kroko-onnx
cd kroko-onnx

# Build both pro + free variants (default)
./build_windows.sh

# Or pick a single variant
./build_windows.sh --variant pro
./build_windows.sh --variant free
```

Requires Docker (or Docker Desktop) with the `linux/amd64` platform available.
The first run pulls the build image and warms the FetchContent cache for openfst /
onnxruntime; subsequent runs are much faster.

#### From a Windows host (Docker Desktop)

A `.bat` port of the same script:

```bat
git clone https://github.com/kroko-ai/kroko-onnx
cd kroko-onnx

build_windows.bat
build_windows.bat --variant pro
build_windows.bat --variant free
```

Requires Docker Desktop (WSL2 backend) and PowerShell 5+ (ships with Windows 10/11).

#### Outputs

```
release_artifacts/windows/
├── kroko-onnx-websocket-server-<version>-pro-setup.exe        # NSIS installer (pro)
├── kroko-onnx-websocket-server-<version>-free-setup.exe       # NSIS installer (free)
├── kroko_onnx-<version>-1pro-cp312-cp312-win_amd64.whl        # Python wheel (pro)
├── kroko_onnx-<version>-1free-cp312-cp312-win_amd64.whl       # Python wheel (free)
├── bin-pro/                                                    # raw artefacts (pro)
└── bin-free/                                                   # raw artefacts (free)
```

The installer ships the websocket-server `.exe` plus every runtime DLL it needs and
chain-installs Microsoft's Visual C++ Redistributable. The wheel bundles all
runtime DLLs via `delvewheel`, so `pip install kroko_onnx-*.whl` works standalone.

The two wheel filenames carry different PEP 425 build tags (`1pro` / `1free`) so
they can sit side-by-side on disk without colliding; install whichever variant you
need:

```bat
pip install kroko_onnx-<version>-1pro-cp312-cp312-win_amd64.whl
```

---

## 2. Usage Examples (WebSocket Server)

```bash
./kroko-onnx-online-websocket-server --key=LICENSE_KEY --model=/path/to/model.data
```

Starts the server listening on the **default port (6006)**.

```bash
./kroko-onnx-online-websocket-server --key=LICENSE_KEY --port=6007 --model=/path/to/model.data
```

Starts the server listening on a **specified port**.

```bash
./kroko-onnx-online-websocket-server --help
```

Shows the full list of parameters.

---

### WebSocket Server Format

#### Input

- The samples should be **16kHz**, **single channel**, and **16-bit**.
- The WebSocket connection accepts a buffer in the following format:
  - `data`: float32 buffer

##### Python Example: Convert Audio to Float32 Buffer

```python
samples = f.readframes(num_samples)
samples_int16 = np.frombuffer(samples, dtype=np.int16)
samples_float32 = samples_int16.astype(np.float32)
buf = samples_float32.tobytes()
```

---

#### Output

The result is in **JSON** format:

```json
{
  "type": "partial",
  "text": "Text from the current segment",
  "segment": 0,
  "startedAt": 0.0,
  "elements": {
    "segments": [
      {
        "type": "segment",
        "text": "",
        "startedAt": 0.0,
        "segment": 0
      }
    ],
    "words": [
      {
        "type": "word",
        "text": "",
        "startedAt": 0.0,
        "segment": 0
      }
    ]
  }
}
```

---

#### Output Fields

Each section contains the following elements:

##### `type` – The type of the element:

- `final` – the full text of the decoded segment  
- `partial` – the text of a not-yet-finished segment  
- `segment` – part of the transcript, same as the text in the main segment (for Banafo Online).  
- `word` – individual word

##### `text`

The transcript of the segment or individual word.

##### `startedAt`

The timestamp (in seconds, float value) indicating the beginning of the element.  
> Example: `1.42` = 1 second and 420 milliseconds

##### `elements`

Contains:

- `segments`: array of segment objects  
- `words`: array of word objects

---

## 3. Using `kroko-onnx` from Python

### Import and Create a Recognizer

```python
import kroko_onnx

recognizer = kroko_onnx.OnlineRecognizer.from_transducer(
    model_path="path/to/model",
    key="",
    referralcode="",
    num_threads=1,
    provider="cpu",
    sample_rate=16000,
    decoding_method="modified_beam_search",
    blank_penalty=0.0,
    enable_endpoint_detection=True,
    rule1_min_trailing_silence=2.4,
    rule2_min_trailing_silence=1.2,
    rule3_min_utterance_length=20.0,
)
```

> ⚠️ Only `model_path` is required. All other parameters are optional.

---

### Parameter Reference

| Argument                     | Type     | Default     | Description |
|-----------------------------|----------|-------------|-------------|
| `model_path`                | `str`    | **Required** | Path to the Kroko model file. |
| `key`                       | `str`    | `""`        | License key. Required only for **Pro models**. |
| `referralcode`              | `str`    | `""`        | Optional project referral code. Contact Kroko for revenue sharing options. |
| `num_threads`               | `int`    | `1`         | Number of threads used for neural network computation. |
| `provider`                  | `str`    | `"cpu"`     | Execution provider. Valid values: `cpu`, `cuda`, `coreml`. |
| `sample_rate`               | `int`    | `16000`     | Sample rate of the input audio. Resampling is performed if it differs. |
| `decoding_method`           | `str`    | `"modified_beam_search"` | Valid values: `greedy_search`, `modified_beam_search`. |
| `blank_penalty`             | `float`  | `0.0`       | Penalty applied to the blank symbol during decoding (applied as: `logits[:, 0] -= blank_penalty`). |
| `enable_endpoint_detection`| `bool`   | `True`      | Enables endpoint detection using rule-based logic. |
| `rule1_min_trailing_silence`| `float` | `2.4`       | Rule 1: Minimum trailing silence (in seconds) to trigger endpoint. |
| `rule2_min_trailing_silence`| `float` | `1.2`       | Rule 2: Minimum trailing silence (in seconds) to trigger endpoint. |
| `rule3_min_utterance_length`| `float` | `20.0`      | Rule 3: Minimum utterance length (in seconds) to trigger endpoint. |

---

### Running the Recognizer on Audio Files

Below is a complete example of how to use the recognizer to transcribe one or more `.wav` files:

```python
import numpy as np
from kroko_onnx.utils import read_wave, assert_file_exists

streams = []
total_duration = 0

for wave_filename in args.sound_files:
    assert_file_exists(wave_filename)

    samples, sample_rate = read_wave(wave_filename)
    duration = len(samples) / sample_rate
    total_duration += duration

    # Create a new stream for this audio
    s = recognizer.create_stream()

    # Send waveform data
    s.accept_waveform(sample_rate, samples)

    # Add 0.66 seconds of padding silence
    tail_paddings = np.zeros(int(0.66 * sample_rate), dtype=np.float32)
    s.accept_waveform(sample_rate, tail_paddings)

    s.input_finished()
    streams.append(s)

# Decode all ready streams in parallel
while True:
    ready_list = [s for s in streams if recognizer.is_ready(s)]
    if not ready_list:
        break
    recognizer.decode_streams(ready_list)

# Collect results
results = [recognizer.get_result(s) for s in streams]

# Print transcriptions
for i, result in enumerate(results):
    print(f"{args.sound_files[i]}: {result.text}")
```

---

> 🔁 You can process multiple files at once using this pattern.  
> 📎 Each stream corresponds to one audio file.
