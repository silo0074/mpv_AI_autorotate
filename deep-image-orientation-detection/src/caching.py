import os
import logging
from PIL import Image
from tqdm import tqdm
from multiprocessing import Pool, cpu_count
import config
from src.utils import load_image_safely


def process_and_cache_image(image_path: str):
    """
    Worker function to process a single image. It uses the robust loader,
    creates four rotated versions, and saves them to the cache directory.
    """
    try:
        cache_dir = config.CACHE_DIR
        original_filename = os.path.splitext(os.path.basename(image_path))[0]

        # Use the single, robust image loader from utils
        img = load_image_safely(image_path)

        # Use the rotation definition from config
        for label, angle in config.ROTATIONS.items():
            rotated_img = img.rotate(angle, resample=Image.BICUBIC, expand=True)
            cached_filename = f"{original_filename}__{label}.png"
            save_path = os.path.join(cache_dir, cached_filename)
            rotated_img.save(save_path, "PNG")

        return None

    except Exception as e:
        logging.warning(f"Could not process and cache {image_path}. Error: {e}")
        return image_path


def cache_dataset(force_rebuild=False):
    """
    Applies rotations to all images and saves them to a cache, using
    multiple processes.
    """
    upright_dir = config.DATA_DIR
    cache_dir = config.CACHE_DIR

    if not os.path.exists(upright_dir):
        logging.error(f"Source data directory not found: {upright_dir}")
        raise FileNotFoundError(f"Source data directory not found: {upright_dir}")

    os.makedirs(cache_dir, exist_ok=True)

    # --- Enhanced Cache Check & Logging ---
    cached_files = os.listdir(cache_dir)
    if force_rebuild:
        logging.info(
            f"Force rebuild is True. Clearing {len(cached_files)} files from cache directory: {cache_dir}"
        )
        for f in cached_files:
            os.remove(os.path.join(cache_dir, f))
        cached_files = []  # Reset file list

    if cached_files:
        logging.info(
            f"Cache already exists with {len(cached_files)} files at '{cache_dir}'. Skipping rebuild."
        )
        return
    else:
        logging.info("Cache is empty or was cleared. Starting build process...")

    image_files = [
        os.path.join(root, f)
        for root, _, files in os.walk(upright_dir)
        for f in files
        if f.lower().endswith((".png", ".jpg", ".jpeg"))
    ]

    if not image_files:
        raise ValueError(f"No images found in {upright_dir}")

    num_workers = config.NUM_WORKERS if config.NUM_WORKERS > 0 else cpu_count()
    logging.info(f"Building cache with {num_workers} worker processes...")

    with Pool(processes=num_workers) as pool:
        results = list(
            tqdm(
                pool.imap_unordered(process_and_cache_image, image_files),
                total=len(image_files),
                desc="Caching Images",
            )
        )

    failures = [r for r in results if r is not None]
    if failures:
        logging.warning(
            f"Warning: {len(failures)} out of {len(image_files)} images failed to process. Check logs for details."
        )

    logging.info(
        f"Successfully built image cache with {len(os.listdir(cache_dir))} files."
    )
