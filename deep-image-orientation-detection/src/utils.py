import torch
import logging
import sys
import torchvision.transforms as transforms
from config import IMAGE_SIZE
from PIL import Image, ImageOps


def setup_logging():
    """Configures the logging for the application."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


def get_device() -> torch.device:
    """
    Selects the best available device (CUDA, MPS, or CPU) and returns it.
    """
    if torch.cuda.is_available():
        device = torch.device("cuda")
        logging.info("CUDA is available. Using GPU.")
    elif torch.backends.mps.is_available():
        device = torch.device("mps")
        logging.info("MPS is available. Using Apple Silicon GPU.")
    else:
        device = torch.device("cpu")
        logging.info("CUDA and MPS not available. Using CPU.")
    return device


def get_data_transforms() -> dict:
    """
    Returns a dictionary of data transformations for training and validation.
    """
    return {
        "train": transforms.Compose(
            [
                # Use a crop that preserves more of the image center
                transforms.RandomResizedCrop(IMAGE_SIZE, scale=(0.85, 1.0)),
                # ColorJitter is a good augmentation that doesn't affect orientation
                transforms.ColorJitter(
                    brightness=0.2, contrast=0.2, saturation=0.2, hue=0.1
                ),
                # RandomErasing is also a good regularizer
                transforms.ToTensor(),
                transforms.Normalize(
                    mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
                ),
                transforms.RandomErasing(p=0.25, scale=(0.02, 0.1)),
            ]
        ),
        "val": transforms.Compose(
            [
                # Validation transform is fine as is
                transforms.Resize((IMAGE_SIZE + 32, IMAGE_SIZE + 32)),
                transforms.CenterCrop(IMAGE_SIZE),
                transforms.ToTensor(),
                transforms.Normalize(
                    mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
                ),
            ]
        ),
    }


def load_image_safely(path: str) -> Image.Image:
    """
    Loads an image, respects EXIF orientation, and safely converts it to a
    3-channel RGB format. It handles palletized images and images with
    transparency by compositing them onto a white background. This is the
    most robust way to prevent processing errors.
    """
    # 1. Open the image
    img = Image.open(path)

    # 2. Respect the EXIF orientation tag before any other processing.
    img = ImageOps.exif_transpose(img)

    # 3. If the image is already in a simple mode that can be directly
    #    converted to RGB, do it and return.
    if img.mode in ("RGB", "L"):  # L is grayscale
        return img.convert("RGB")

    # 4. For all other modes (including P, PA, RGBA, etc.), convert to RGBA
    #    first. This is the crucial step that standardizes the image
    #    and correctly handles transparency.
    rgba_img = img.convert("RGBA")

    # 5. Create a new white background image in RGB mode.
    background = Image.new("RGB", rgba_img.size, (255, 255, 255))

    # 6. Paste the RGBA image onto the white background. The `rgba_img`
    #    itself is used as the mask, which tells Pillow to use its alpha channel.
    background.paste(rgba_img, mask=rgba_img)

    return background
