# mpv AI Auto-Rotate

[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://github.com/silo0074/mpv_AI_autorotate/blob/main/LICENSE)

A smart `mpv` script that uses a machine learning model to automatically detect and correct the orientation of sideways or upside-down videos. It also features automatic black bar cropping and integration with SMPlayer.

---

## Table of Contents
* [Description](#description)
* [How It Works](#how-it-works)
* [Features](#features)
* [Installation](#installation)
* [Usage](#usage)
* [SMPlayer Tips](#smplayer-tips)

---

## Description

Have you ever loaded a video from your phone only to find yourself craning your neck because it's playing sideways? This project solves that problem. It's a "set it and forget it" solution that intelligently analyzes video content and applies the correct rotation, creating a seamless viewing experience, especially when watching a mix of landscape and portrait videos.

Most of the time when doing tutorials I film using multiple video segments that I merge in a video editor, just to realize that I forget to maintain the same video orientation. In order to stitch these you have to create a square container (e.g. 1920x1920) but then you need to zoom in for landscape segments so for this reason I added an auto cropping functionality. Since I already had the script doing AI automatic rotation and auto cropping I was thinking what else could it solve and I remembered about this issue in SMplayer where if you use hardware acceleration even in copy mode, it doesn't load filters such as rotation or flip even though it is selected in GUI. With this new feature, the script checks the INI file that SMplayer saves for every file and loads the rotation filter.

I am using SMplayer version 24.5.0 since versions 25.x and newer have a regression where rotating a video (either manually or via a script) results in an incorrect aspect ratio. The window geometry does not update correctly, causing the video to appear stretched or squashed.

This project is based on this AI model: [deep-image-orientation-detection](https://github.com/duartebarbosadev/deep-image-orientation-detection) by [duartebarbosadev](https://github.com/duartebarbosadev). You can use any model you want but it has to be specifically trained to detect orientation. A classification model that only detects objects won't work. The folder `deep-image-orientation-detection` is a clone of the above project with a modified version of `convert_to_onnx.py` where I modified `opset_version` to 11 to be compatible with my older NVidia card GTX 950. The model `orientation_model_v2_0.9882.pth` was downloaded from the [Releases](https://github.com/duartebarbosadev/deep-image-orientation-detection/releases) section where you can also download the .onnx version which is much more efficient. Since my graphic card is older, the onnx model didn't work for me so I used `convert_to_onnx.py` to convert the .pth to .onnx which are the `orientation_model_v2_0.9882.onnx` and `orientation_model_v2_0.9882.onnx.data` files in the root folder. If desired the model can be fine-tuned on more data sets.

In the `ai_listener.py` the model is loaded using `OpenVINOExecutionProvider` to use the Intel GPU but I believe it still uses my NVidia card but using `OpenVINOExecutionProvider` makes it more compatible with older cards.

If you want to learn a few basic concepts about artificial intelligence I recommend reading this article: [Correcting Image Orientation Using Convolutional Neural Networks](https://d4nst.github.io/2017/01/12/image-orientation/).

## How It Works

The system is composed of two main parts:
1.  **`ai_rotate.lua`**: A script that runs inside `mpv`. It handles communication, applies video filters, and displays status information on the OSD.
2.  **`ai_listener.py`**: A Python backend server that performs the heavy lifting. It uses an ONNX machine learning model to classify video orientation.

The workflow is as follows:
1.  When you open a video in `mpv` or `SMplayer` which uses `mpv`, the Lua script checks if the filename contains a trigger keyword (default: `rotate`).
2.  If the keyword is found, the AI mode is activated. The script automatically starts the Python backend if it's not already running.
3.  Periodically, the Lua script captures a raw video frame and sends it to the Python server.
4.  The Python server receives the frame, preprocesses it (resizing with letterboxing, normalization), and feeds it into the orientation detection model.
5.  The model predicts the necessary rotation (0°, 90°, 180°, or 270°). 0 means no rotation is needed.
6.  To prevent flickering, the server waits for a few consistent predictions before making a decision.
7.  The final, stable rotation is sent back to the Lua script, which applies it in `mpv` as a video filter.

## Features

*   **AI-Powered Auto-Rotation**: Intelligently detects and corrects video orientation.
*   **Keyword Activation**: The AI only runs on files you want it to, saving resources.
*   **Automatic Black Bar Cropping**: Uses `cropdetect` to automatically detect and trim letterboxing or pillarboxing, maximizing screen space.
*   **SMPlayer Integration**: Reads SMPlayer's `.ini` files to restore your last saved rotation for a specific video.
*   **High-Performance Backend**: uses ONNX Runtime with OpenVINO for efficient GPU-accelerated inference.
*   **Stable & Reliable**: A history-based voting mechanism prevents unwanted rotations from transient or low-confidence detections.
*   **Informative OSD**: A clean On-Screen Display shows the current mode (AI/Manual), rotation angle, and cropping status.

## Installation

1.  **Prerequisites**:
    *   `mpv` or `SMPlayer` media player.
    *   `python3` and `pip`.
    *   `socat`: A command-line utility for data transfer. Install it via your system's package manager (e.g., `sudo apt-get install socat` or `sudo pacman -S socat`).

2.  **Clone the Repository**:
    ```bash
    git clone https://github.com/silo0074/mpv_AI_autorotate.git
    cd mpv_ai_autorotate
    ```

3.  **Set up the Python Environment**: Using a virtual environment is highly recommended.
    ```bash
    python3 -m venv env
    source env/bin/activate
    pip install numpy opencv-python onnxruntime-openvino
    ```

4.  **Configure the Lua Script**:
    *   Open `ai_rotate.lua` in a text editor.
    *   At the top of the file, update the `python_path` and `server_script` variables to match the absolute paths on your system.

    ```lua
    local python_path = "/path/to/your/project/mpv_ai_autorotate/env/bin/python3"
    local server_script = "/path/to/your/project/mpv_ai_autorotate/ai_listener.py"
    ```

5.  **Install the Lua Script**:
    *   Copy or create a symbolic link of `ai_rotate.lua` into your `mpv` scripts directory.
    *   Linux: `ln -s /path/to/your/project/ai_rotate.lua ~/.config/mpv/scripts/ai_rotate.lua`
    *   The script can also be passed as an argument to mpv or SMPlayer if you don't want to place it in mpv's config folder. If you are using SMPlayer, the Lua script can be added in **Options** -> **Preferences** -> **Advanced** -> **MPlayer/mpv** and in the **Options** field add

    ```lua
    --scripts=/path/to/your/project/mpv_ai_autorotate/ai_rotate.lua
    ```

## Usage

1.  **Activate AI**: To enable auto-rotation for a video, simply ensure its filename contains the keyword `rotate` (e.g., `my_phone_video_rotate.mp4`).
2.  **Play the Video**: Open the file with `mpv` or `SMPlayer`. The script will automatically launch the Python backend.
3.  **Monitor Status**: The OSD in the top-left corner will display `AI` and the current rotation angle (e.g., `AI90`). If autocrop is active, `CR` will appear below the angle.

## SMPlayer tips

* Output driver: **Options** -> **Preferences** -> **General** -> **Video** and select gpu-next.
* Hardware decoding: **Options** -> **Preferences** -> **Performance** -> **Decoding** and select `auto-copy`. Because filters like rotation cannot be applied directly on the GPU, `auto-copy` tells mpv to copy the decoded frame back to system memory (CPU) to apply the filter before displaying it. This is necessary for this script to function correctly with hardware decoding. If you don't need filters then it is more efficient to just use `auto`, or `nvdec` if you have an NVidia card or anything else without the copy subfix.
* If video doesn't show or have other issues, use OpenGL by placing `--gpu-api=opengl` in Options field under **Options** -> **Preferences** -> **Advanced** -> **MPlayer/mpv**.
* If you notice video tearing it can be caused by the video FPS not matching the display refresh rate. If you have an NVidia card, try to enable `Force Full Composition Pipeline` in `NVidia Settings` under **X Server Display Configuration** -> **Advanced**.

## ❤️ Donations

<a href="https://www.buymeacoffee.com/liviuistrate" target="_blank">
  <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="60px" width="217px">
</a>