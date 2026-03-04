import os
import random
import torch
import logging
import numpy as np
from torch.utils.data import Dataset
from PIL import Image

import torchvision.transforms as transforms
import config
from src.utils import load_image_safely


# Dataset for cases where caching is not desired
class ImageOrientationDataset(Dataset):
    def __init__(self, upright_dir, transform=None):
        self.upright_dir = upright_dir
        self.image_files = []
        for root, _, files in os.walk(upright_dir):
            for filename in files:
                if filename.lower().endswith((".png", ".jpg", ".jpeg")):
                    self.image_files.append(os.path.join(root, filename))

        if not self.image_files:
            raise ValueError(f"No images found in the directory: {upright_dir}")

        self.transform = transform
        # Use the rotation definition from config
        self.rotations = config.ROTATIONS
        self.num_rotations = len(self.rotations)

    def __len__(self):
        return len(self.image_files) * self.num_rotations

    def __getitem__(self, idx):
        image_idx = idx // self.num_rotations
        label = idx % self.num_rotations

        image_path = self.image_files[image_idx]
        angle_to_rotate = self.rotations[label]

        try:
            # Use the safe loader from utils
            image = load_image_safely(image_path)
            # Apply the selected rotation
            rotated_image = image.rotate(
                angle_to_rotate, resample=Image.BICUBIC, expand=True
            )

            if self.transform:
                image_tensor = self.transform(rotated_image)
            else:
                # Default minimal transformation if none provided
                image_tensor = transforms.ToTensor()(rotated_image)

        except Exception as e:
            logging.warning(
                f"Warning: Could not open or process {image_path}. Skipping. Error: {e}"
            )
            # Return a random sample to avoid crashing the loader
            return self.__getitem__(random.randint(0, len(self) - 1))

        return image_tensor, torch.tensor(label, dtype=torch.long)


# This dataset reads directly from the pre-processed and cached images.
# This is significantly faster (if run on a fast disk) as it only has to do a file read and basic tensor conversion.
class ImageOrientationDatasetFromCache(Dataset):
    def __init__(self, cache_dir, transform=None):
        self.cache_dir = cache_dir
        self.transform = transform

        if not os.path.exists(cache_dir) or not os.listdir(cache_dir):
            raise FileNotFoundError(
                f"Cache directory is empty or does not exist: '{cache_dir}'. "
                "Run the caching process in `train.py` first."
            )

        self.image_files = [
            os.path.join(cache_dir, f)
            for f in os.listdir(cache_dir)
            if f.endswith(".png")
        ]

        if not self.image_files:
            raise ValueError(
                f"No .png images found in the cache directory: {cache_dir}"
            )

    def __len__(self):
        return len(self.image_files)

    def __getitem__(self, idx):
        image_path = self.image_files[idx]

        try:
            # The label is encoded in the filename (e.g., "my_image__2.png" -> label 2).
            # This logic robustly finds the last "__" and parses the number after it,
            # correctly handling filenames that might contain underscores.
            filename_no_ext = os.path.splitext(os.path.basename(image_path))[0]
            last_sep_idx = filename_no_ext.rfind("__")
            if last_sep_idx == -1:
                raise ValueError(
                    f"Filename '{image_path}' does not contain the '__' separator."
                )

            label_str = filename_no_ext[last_sep_idx + 2 :]
            label = int(label_str)

            # Load the already-rotated image
            image = load_image_safely(image_path)

            if self.transform:
                image_tensor = self.transform(image)
            else:
                image_tensor = transforms.ToTensor()(image)

        except Exception as e:
            logging.warning(
                f"Could not read or process cached file {image_path}. Error: {e}"
            )
            return self.__getitem__(random.randint(0, len(self) - 1))

        return image_tensor, torch.tensor(label, dtype=torch.long)
