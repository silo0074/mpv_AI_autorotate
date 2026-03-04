import torch
import torch.onnx
import onnx
import onnxruntime
import numpy as np
import argparse
import os
from src.model import get_orientation_model
from src.utils import get_device
from config import IMAGE_SIZE


def convert_to_onnx(model_path, onnx_file_name):
    # FORCE CPU for export - bypasses the sm_52 error
    device = torch.device("cpu")
    model = get_orientation_model(pretrained=False)

    # Load state dict strictly to CPU
    state_dict = torch.load(model_path, map_location=device)
    model.load_state_dict(state_dict)
    model.eval()

    # Dummy input on CPU
    dummy_input = torch.randn(1, 3, 384, 384)

    print("Exporting model to ONNX Opset 11...")
    torch.onnx.export(
        model,
        dummy_input,
        onnx_file_name,
        export_params=True,
        opset_version=11, # Opset 11 is the 'safe mode' for GTX 950
        do_constant_folding=True,
        input_names=["input"],
        output_names=["output"],
        # Disabling dynamic_axes can sometimes solve the 'Assertion node found' error
        dynamic_axes=None
    )

    print(f"Model successfully exported to {onnx_file_name}")

    # --- VERIFICATION PROCESS ---
    print("\nVerifying the ONNX model...")

    # Check that the ONNX model is well-formed
    onnx_model = onnx.load(onnx_file_name)
    onnx.checker.check_model(onnx_model)
    print("ONNX model check passed.")

    # Create an ONNX Runtime inference session
    ort_session = onnxruntime.InferenceSession(onnx_file_name)

    # Get the output from the PyTorch model
    with torch.no_grad():
        pytorch_out = model(dummy_input)

    # Get the output from the ONNX Runtime
    ort_inputs = {ort_session.get_inputs()[0].name: dummy_input.detach().cpu().numpy()}
    ort_outs = ort_session.run(None, ort_inputs)

    # Compare the outputs
    np.testing.assert_allclose(
        pytorch_out.cpu().numpy(), ort_outs[0], rtol=0.2, atol=0.01
    )

    print("Verification successful: PyTorch and ONNX Runtime outputs match.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Convert a PyTorch model to ONNX format."
    )
    parser.add_argument(
        "model_path", type=str, help="Path to the PyTorch model (.pth) file."
    )
    args = parser.parse_args()

    # Create the output path for the ONNX model
    base_path = os.path.splitext(args.model_path)[0]
    onnx_file_name = f"{base_path}.onnx"

    print(f"Converting model {args.model_path} to {onnx_file_name}")
    convert_to_onnx(args.model_path, onnx_file_name)
