import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, random_split, Subset
from copy import deepcopy
import os
import argparse
import logging
import shutil
import time

import torch.amp as amp
import config
from src.caching import cache_dataset
from src.dataset import ImageOrientationDataset, ImageOrientationDatasetFromCache
from src.model import get_orientation_model
from src.utils import get_device, setup_logging, get_data_transforms
import torch.optim.lr_scheduler as lr_scheduler
from torch.utils.tensorboard import SummaryWriter


def train(args):
    """Main training routine."""
    setup_logging()
    training_start_time = time.time()

    logging.info("=================================================")
    logging.info("      STARTING MODEL TRAINING SCRIPT")
    logging.info("=================================================")
    logging.info("Configuration:")
    logging.info(f"  - Using Cache: {config.USE_CACHE}")
    if config.USE_CACHE:
        logging.info(f"  - Cache Directory: {config.CACHE_DIR}")
        logging.info(f"  - Force Rebuild Cache: {args.force_rebuild_cache}")
    logging.info(f"  - Resume from checkpoint: {args.resume}")
    logging.info(f"  - Source Data Directory: {args.data_dir}")
    logging.info(f"  - Model Save Directory: {args.model_dir}")
    logging.info(f"  - Number of Epochs: {args.epochs}")
    logging.info(f"  - Batch Size: {args.batch_size}")
    logging.info(f"  - Learning Rate: {args.lr}")
    logging.info(f"  - Dataloader Workers: {args.workers}")

    writer = SummaryWriter(f"runs/{config.MODEL_NAME}")

    # Ensure model save directory exists
    os.makedirs(args.model_dir, exist_ok=True)

    device = get_device()

    # Determine if pin_memory should be used
    pin_memory_enabled = device.type == "cuda"
    if pin_memory_enabled:
        logging.info("CUDA detected, pin_memory will be enabled for DataLoaders.")
    else:
        logging.info("CUDA not detected, pin_memory will be disabled.")

    ### Dataset and Dataloader logic
    logging.info("\n--- Initializing Dataset and Dataloaders ---")
    data_transforms = get_data_transforms()

    # 1. Create a single, full dataset instance without any transforms yet.
    #    This 'base_dataset' will be the source for our splits.
    try:
        if config.USE_CACHE:
            cache_dataset(force_rebuild=args.force_rebuild_cache)
            base_dataset = ImageOrientationDatasetFromCache(
                cache_dir=config.CACHE_DIR, transform=None
            )
            logging.info(
                f"Successfully loaded dataset from CACHE ({len(base_dataset)} images)."
            )
        else:
            logging.info("Using ON-THE-FLY image processing (caching is disabled).")
            base_dataset = ImageOrientationDataset(
                upright_dir=args.data_dir, transform=None
            )
            logging.info(f"Successfully loaded dataset for on-the-fly processing.")
            logging.info(
                f"Dataset found {len(base_dataset.image_files)} original image files."
            )
            logging.info(f"Total dataset size (with 4 rotations): {len(base_dataset)}")

    except (ValueError, FileNotFoundError) as e:
        logging.error(f"Failed to initialize dataset: {e}")
        return

    # 2. Split the single dataset instance *once* to get disjoint sets of indices.
    train_size = int(0.8 * len(base_dataset))
    val_size = len(base_dataset) - train_size
    # For reproducibility, you could use a torch.Generator: g = torch.Generator().manual_seed(42)
    train_subset, val_subset = random_split(base_dataset, [train_size, val_size])

    # 3. Apply the correct transforms to each subset *after* splitting.
    #    We create deepcopies of the base dataset, each with its own transform,
    #    and assign them to the appropriate subset. This prevents the validation
    #    set from seeing augmented training data.
    train_subset.dataset = deepcopy(base_dataset)
    train_subset.dataset.transform = data_transforms["train"]

    val_subset.dataset = deepcopy(base_dataset)
    val_subset.dataset.transform = data_transforms["val"]

    logging.info(
        f"Splitting into Training: {len(train_subset)} samples, Validation: {len(val_subset)} samples."
    )

    train_loader = DataLoader(
        train_subset,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=args.workers,
        pin_memory=pin_memory_enabled,
        persistent_workers=True,
    )
    val_loader = DataLoader(
        val_subset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.workers,
        pin_memory=pin_memory_enabled,
        persistent_workers=True,
    )
    logging.info("Dataloaders created successfully.")

    logging.info("\n--- Setting up Model ---")
    # Store the original model instance
    original_model = get_orientation_model().to(device)

    # This will be the model instance used for training/inference during the loop
    model_for_training = original_model

    # Compile the model for performance if PyTorch 2.0+ is used
    if hasattr(torch, "compile"):
        logging.info("PyTorch 2.0+ detected. Compiling the model for performance...")
        model_for_training = torch.compile(original_model, mode="reduce-overhead")

    criterion = nn.CrossEntropyLoss(label_smoothing=0.1)  # Add label_smoothing

    # Initialize optimizer with parameters of the model used for training
    optimizer = optim.AdamW(
        model_for_training.parameters(), lr=args.lr, weight_decay=1e-3
    )
    logging.info(
        f"Using pre-trained {config.MODEL_NAME} model. Final layers is trainable."
    )
    logging.info(f"Optimizer configured with AdamW, LR={args.lr}, Weight Decay=1e-3")

    # Add scheduler
    scheduler = lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=args.epochs, eta_min=1e-6
    )

    # --- Checkpoint Loading ---
    start_epoch = 0
    best_val_acc = 0.0
    epochs_no_improve = 0
    checkpoint_path = os.path.join(args.model_dir, "checkpoint.pth")

    if args.resume and os.path.exists(checkpoint_path):
        logging.info(f"\n--- Resuming training from checkpoint: {checkpoint_path} ---")
        try:
            checkpoint = torch.load(checkpoint_path, map_location=device)

            # Load model state
            original_model.load_state_dict(checkpoint["model_state_dict"])

            # Load optimizer and scheduler states
            optimizer.load_state_dict(checkpoint["optimizer_state_dict"])
            scheduler.load_state_dict(checkpoint["scheduler_state_dict"])

            # Load training progress
            start_epoch = checkpoint["epoch"] + 1
            best_val_acc = checkpoint.get("best_val_acc", 0.0)
            epochs_no_improve = checkpoint.get("epochs_no_improve", 0)

            logging.info(
                f"Resumed from epoch {start_epoch}. Best Val Acc: {best_val_acc:.4f}"
            )
        except Exception as e:
            logging.error(f"Error loading checkpoint: {e}. Starting from scratch.")
            start_epoch = 0
            best_val_acc = 0.0
    else:
        logging.info("\n--- Starting Training Loop from scratch ---")

    # --- Training Loop ---
    early_stop_patience = 7  # Stop after 7 epochs of no improvement

    for epoch in range(start_epoch, args.epochs):
        epoch_start_time = time.time()

        # --- Training Phase ---
        model_for_training.train()
        running_loss, running_corrects = 0.0, 0
        for inputs, labels in train_loader:
            inputs, labels = (
                inputs.to(device, non_blocking=True),
                labels.to(device, non_blocking=True),
            )
            optimizer.zero_grad(set_to_none=True)

            with amp.autocast(device_type="cuda", dtype=torch.bfloat16):
                outputs = model_for_training(inputs)
                loss = criterion(outputs, labels)

            # Backpropagation without scaler
            loss.backward()
            optimizer.step()

            _, preds = torch.max(outputs, 1)
            running_loss += loss.item() * inputs.size(0)
            running_corrects += torch.sum(preds == labels.data)

        epoch_loss = running_loss / len(train_subset)
        epoch_acc = running_corrects.float() / len(train_subset)

        # --- Validation Phase ---
        model_for_training.eval()
        val_loss, val_corrects = 0.0, 0

        with torch.no_grad():
            for inputs, labels in val_loader:
                inputs, labels = (
                    inputs.to(device, non_blocking=True),
                    labels.to(device, non_blocking=True),
                )

                with amp.autocast(device_type="cuda", dtype=torch.bfloat16):
                    outputs = model_for_training(inputs)
                    loss = criterion(outputs, labels)

                _, preds = torch.max(outputs, 1)
                val_loss += loss.item() * inputs.size(0)
                val_corrects += torch.sum(preds == labels.data)

        val_epoch_loss = val_loss / len(val_subset)
        val_epoch_acc = val_corrects.float() / len(val_subset)

        scheduler.step()

        epoch_duration = time.time() - epoch_start_time

        logging.info(
            f"Epoch {epoch + 1:02d}/{args.epochs} | "
            f"Train Loss: {epoch_loss:.4f} Acc: {epoch_acc:.4f} | "
            f"Val Loss: {val_epoch_loss:.4f} Acc: {val_epoch_acc:.4f} | "
            f"LR: {optimizer.param_groups[0]['lr']:.2e} | "
            f"Duration: {epoch_duration:.2f}s"
        )

        # --- TensorBoard Logging ---
        writer.add_scalar("Loss/train", epoch_loss, epoch)
        writer.add_scalar("Accuracy/train", epoch_acc, epoch)
        writer.add_scalar("Loss/validation", val_epoch_loss, epoch)
        writer.add_scalar("Accuracy/validation", val_epoch_acc, epoch)
        writer.add_scalar(
            "Hyperparameters/learning_rate", optimizer.param_groups[0]["lr"], epoch
        )

        # --- MODEL AND CHECKPOINT SAVING LOGIC ---
        current_acc = val_epoch_acc.item()
        if current_acc > best_val_acc:
            best_val_acc = current_acc
            epochs_no_improve = 0  # Reset counter

            # Save the best model (the original, un-compiled version)
            static_save_path = os.path.join(args.model_dir, "best_model.pth")
            torch.save(original_model.state_dict(), static_save_path)

            # Also save a versioned name including the model name and accuracy
            versioned_model_name = f"{config.MODEL_NAME}_{best_val_acc:.4f}.pth"
            versioned_save_path = os.path.join(args.model_dir, versioned_model_name)
            torch.save(original_model.state_dict(), versioned_save_path)

            logging.info(f"   New best model saved! Val Acc: {best_val_acc:.4f}")
            logging.info(
                f"   Model saved as '{static_save_path}' and '{versioned_save_path}'"
            )

        else:
            epochs_no_improve += 1

        # Save checkpoint at the end of every epoch
        checkpoint = {
            "epoch": epoch,
            "model_state_dict": original_model.state_dict(),
            "optimizer_state_dict": optimizer.state_dict(),
            "scheduler_state_dict": scheduler.state_dict(),
            "best_val_acc": best_val_acc,
            "epochs_no_improve": epochs_no_improve,
        }
        torch.save(checkpoint, checkpoint_path)
        logging.debug(f"Checkpoint saved to {checkpoint_path}")

        # --- Check for early stopping ---
        if epochs_no_improve >= early_stop_patience:
            logging.info(
                f"\n--- Early stopping triggered after {early_stop_patience} epochs with no improvement. ---"
            )
            logging.info(
                f"Best validation accuracy was {best_val_acc:.4f} at epoch {epoch - early_stop_patience + 1}."
            )
            break

    # SUMMARY
    total_duration = time.time() - training_start_time
    total_minutes = total_duration / 60
    logging.info("\n=================================================")
    logging.info("              TRAINING COMPLETE")
    logging.info("=================================================")
    logging.info(
        f"Total Training Time: {total_duration:.2f} seconds ({total_minutes:.2f} minutes)"
    )
    if os.path.exists(os.path.join(args.model_dir, "best_model.pth")):
        final_model_name = f"{config.MODEL_NAME}_{best_val_acc:.4f}.pth"
        logging.info(f"Best Validation Accuracy: {best_val_acc:.4f}")
        logging.info(
            f"Final best model saved as 'best_model.pth' and '{final_model_name}'"
        )
    else:
        logging.warning(
            "No model was saved as validation accuracy did not improve from its initial state."
        )
    logging.info("=================================================")

    writer.close()  # Close the TensorBoard writer


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Train an image orientation detection model."
    )
    parser.add_argument(
        "--data_dir",
        type=str,
        default=config.DATA_DIR,
        help="Directory with upright images.",
    )
    parser.add_argument(
        "--model_dir",
        type=str,
        default=config.MODEL_SAVE_DIR,
        help="Directory to save trained models.",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=config.NUM_EPOCHS,
        help="Number of training epochs.",
    )
    parser.add_argument(
        "--batch_size", type=int, default=config.BATCH_SIZE, help="Training batch size."
    )
    parser.add_argument(
        "--lr", type=float, default=config.LEARNING_RATE, help="Learning rate."
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=config.NUM_WORKERS,
        help="Number of data loading workers.",
    )
    parser.add_argument(
        "--force-rebuild-cache",
        action="store_true",
        help="If set, clears and rebuilds the image cache.",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume training from the last checkpoint.",
    )

    args = parser.parse_args()
    train(args)
