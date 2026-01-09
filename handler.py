"""
RunPod Serverless Handler for ComfyUI Video Generation Endpoint
Supports: t2v, i2v, fun_camera, vace
"""
import runpod
import os
import json
import time
import subprocess
import threading
import requests
from requests.exceptions import RequestException
import boto3
from pathlib import Path
from typing import Dict, Any, Optional
import base64
from io import BytesIO
from PIL import Image

# Configuration
WORKFLOWS_DIR = "/comfyui/workflows"
COMFYUI_API_URL = "http://127.0.0.1:8188"
VOLUME_ROOT = os.getenv("VOLUME_ROOT", "/workspace")

# S3 Configuration
S3_ENDPOINT_URL = os.getenv("S3_ENDPOINT_URL")
S3_BUCKET = os.getenv("S3_BUCKET")
S3_ACCESS_KEY_ID = os.getenv("S3_ACCESS_KEY_ID")
S3_SECRET_ACCESS_KEY = os.getenv("S3_SECRET_ACCESS_KEY")

# Available workflows
AVAILABLE_WORKFLOWS = {
    "t2v": "t2v.json",
    "i2v": "i2v.json",
    "fun_camera": "fun_camera.json",
    "vace": "vace.json",
}

# Global ComfyUI process
comfyui_process = None
comfyui_ready = False


def start_comfyui():
    """Start ComfyUI API server in background"""
    global comfyui_process, comfyui_ready
    
    if comfyui_process is not None and comfyui_ready:
        return
    
    if comfyui_process is not None:
        # Check if process is still running
        if comfyui_process.poll() is None:
            return
        else:
            # Process died, restart
            comfyui_process = None
    
    print("Starting ComfyUI API server...")
    
    # Start ComfyUI in background
    comfyui_process = subprocess.Popen(
        ["python", "-u", "/comfyui/main.py", "--port", "8188", "--listen", "127.0.0.1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd="/comfyui"
    )
    
    # Wait for ComfyUI to be ready
    max_retries = 60  # Increased timeout for cold start
    for i in range(max_retries):
        try:
            response = requests.get(f"{COMFYUI_API_URL}/system_stats", timeout=2)
            if response.status_code == 200:
                comfyui_ready = True
                print("ComfyUI API server is ready!")
                return
        except RequestException:
            pass
        
        # Check if process died
        if comfyui_process.poll() is not None:
            stderr_output = comfyui_process.stderr.read() if comfyui_process.stderr else "No error output"
            raise RuntimeError(f"ComfyUI process died: {stderr_output}")
        
        time.sleep(2)
    
    raise RuntimeError("ComfyUI API server failed to start within timeout")


def load_workflow(workflow_type: str) -> Dict[str, Any]:
    """Load workflow JSON file"""
    if workflow_type not in AVAILABLE_WORKFLOWS:
        available = ", ".join(AVAILABLE_WORKFLOWS.keys())
        raise ValueError(f"Unknown workflow_type: {workflow_type}. Available: {available}")
    
    workflow_path = os.path.join(WORKFLOWS_DIR, AVAILABLE_WORKFLOWS[workflow_type])
    
    if not os.path.exists(workflow_path):
        raise FileNotFoundError(f"Workflow file not found: {workflow_path}")
    
    with open(workflow_path, 'r') as f:
        return json.load(f)


def download_image(url: str, save_path: str):
    """Download image from URL"""
    response = requests.get(url, timeout=30)
    response.raise_for_status()
    
    os.makedirs(os.path.dirname(save_path), exist_ok=True)
    with open(save_path, 'wb') as f:
        f.write(response.content)
    
    return save_path


def upload_to_s3(file_path: str, s3_key: str) -> str:
    """Upload file to S3 and return public URL"""
    if not all([S3_ENDPOINT_URL, S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY]):
        raise ValueError("S3 configuration is incomplete")
    
    s3_client = boto3.client(
        's3',
        endpoint_url=S3_ENDPOINT_URL,
        aws_access_key_id=S3_ACCESS_KEY_ID,
        aws_secret_access_key=S3_SECRET_ACCESS_KEY
    )
    
    s3_client.upload_file(file_path, S3_BUCKET, s3_key)
    
    # Construct public URL
    if S3_ENDPOINT_URL.endswith('/'):
        base_url = S3_ENDPOINT_URL[:-1]
    else:
        base_url = S3_ENDPOINT_URL
    
    return f"{base_url}/{S3_BUCKET}/{s3_key}"


def queue_workflow(workflow: Dict[str, Any]) -> str:
    """Queue workflow in ComfyUI and return prompt_id"""
    response = requests.post(
        f"{COMFYUI_API_URL}/prompt",
        json={"prompt": workflow},
        timeout=10
    )
    response.raise_for_status()
    return response.json()["prompt_id"]


def wait_for_completion(prompt_id: str, timeout: int = 600) -> Dict[str, Any]:
    """Wait for workflow completion and return outputs"""
    start_time = time.time()
    
    while time.time() - start_time < timeout:
        response = requests.get(f"{COMFYUI_API_URL}/history/{prompt_id}", timeout=5)
        history = response.json()
        
        if prompt_id in history:
            output = history[prompt_id]["outputs"]
            if output:
                return output
        
        time.sleep(1)
    
    raise TimeoutError(f"Workflow {prompt_id} did not complete within {timeout} seconds")


def get_output_files(outputs: Dict[str, Any]) -> list:
    """Extract output file paths from ComfyUI outputs (images and videos)"""
    files = []
    
    for node_id, node_output in outputs.items():
        # Check for images
        if "images" in node_output:
            for image_info in node_output["images"]:
                if "filename" in image_info:
                    file_path = os.path.join("/comfyui/output", image_info["filename"])
                    if os.path.exists(file_path):
                        files.append(file_path)
        
        # Check for videos
        if "videos" in node_output:
            for video_info in node_output["videos"]:
                if "filename" in video_info:
                    file_path = os.path.join("/comfyui/output", video_info["filename"])
                    if os.path.exists(file_path):
                        files.append(file_path)
    
    return files


def update_workflow_with_inputs(workflow: Dict[str, Any], params: Dict[str, Any]) -> Dict[str, Any]:
    """Update workflow nodes with input parameters"""
    # Update text prompts
    for node_id, node in workflow.items():
        if node.get("class_type") == "CLIPTextEncode":
            if "text" in node.get("inputs", {}):
                if "positive_prompt" in params:
                    node["inputs"]["text"] = params["positive_prompt"]
                elif "prompt" in params:
                    node["inputs"]["text"] = params["prompt"]
        
        # Update image inputs
        if node.get("class_type") == "LoadImage":
            if "image_url" in params:
                # Download image and update path
                image_path = download_image(
                    params["image_url"],
                    f"/tmp/input_image_{node_id}.png"
                )
                node["inputs"]["image"] = os.path.basename(image_path)
    
    return workflow


def handler(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    RunPod handler function
    
    Expected input:
    {
        "workflow_name": "character_sheet",
        "workflow_json": {...},  # Optional: override workflow
        "params": {
            "prompt": "...",
            "positive_prompt": "...",
            "negative_prompt": "...",
            "image_url": "...",  # For image-to-image workflows
            "seed": 12345,
            "steps": 20,
            "cfg": 7.0,
            ...
        },
        "input_assets": [  # Optional: additional input files
            {"type": "image", "url": "..."},
            {"type": "video", "url": "..."}
        ]
    }
    
    Returns:
    {
        "status": "COMPLETED",
        "outputs": [
            {"type": "image", "url": "https://..."},
            ...
        ],
        "metadata": {
            "workflow_name": "...",
            "execution_time": 45.2,
            "prompt_id": "..."
        }
    }
    """
    global comfyui_ready
    
    start_time = time.time()
    
    try:
        # Ensure ComfyUI is running
        if not comfyui_ready:
            start_comfyui()
        
        # Parse input
        input_data = event.get("input", {})
        workflow_name = input_data.get("workflow_name")
        workflow_json = input_data.get("workflow_json")
        params = input_data.get("params", {})
        input_assets = input_data.get("input_assets", [])
        
        if not workflow_name and not workflow_json:
            return {
                "error": "workflow_name or workflow_json is required",
                "status": "FAILED"
            }
        
        # Load workflow
        if workflow_json:
            workflow = workflow_json
        else:
            workflow = load_workflow(workflow_name)
        
        # Update workflow with parameters
        workflow = update_workflow_with_inputs(workflow, params)
        
        # Queue workflow
        prompt_id = queue_workflow(workflow)
        
        # Wait for completion
        outputs = wait_for_completion(prompt_id)
        
        # Get output files
        output_files = get_output_files(outputs)
        
        if not output_files:
            return {
                "error": "No output files generated",
                "status": "FAILED"
            }
        
        # Upload to S3
        output_urls = []
        timestamp = int(time.time())
        
        for i, file_path in enumerate(output_files):
            file_ext = os.path.splitext(file_path)[1]
            s3_key = f"generated/{workflow_name}/{timestamp}_{i}{file_ext}"
            
            try:
                url = upload_to_s3(file_path, s3_key)
                file_type = "video" if file_ext in [".mp4", ".webm", ".avi", ".mov"] else "image" if file_ext in [".png", ".jpg", ".jpeg"] else "unknown"
                output_urls.append({
                    "type": file_type,
                    "url": url,
                    "filename": os.path.basename(file_path)
                })
            except Exception as e:
                print(f"Failed to upload {file_path} to S3: {e}")
                # Fallback: return base64 encoded file (for small files only)
                file_size = os.path.getsize(file_path)
                if file_size < 10 * 1024 * 1024:  # Only for files < 10MB
                    with open(file_path, 'rb') as f:
                        file_data = base64.b64encode(f.read()).decode('utf-8')
                        file_type = "video" if file_ext in [".mp4", ".webm", ".avi", ".mov"] else "image"
                        output_urls.append({
                            "type": file_type,
                            "data": file_data,
                            "format": file_ext[1:]
                        })
                else:
                    output_urls.append({
                        "type": "error",
                        "error": f"File too large for base64 encoding: {file_size} bytes"
                    })
        
        execution_time = time.time() - start_time
        
        return {
            "status": "COMPLETED",
            "outputs": output_urls,
            "metadata": {
                "workflow_name": workflow_name,
                "execution_time": round(execution_time, 2),
                "prompt_id": prompt_id
            }
        }
    
    except Exception as e:
        return {
            "error": str(e),
            "status": "FAILED",
            "execution_time": time.time() - start_time
        }


# Start ComfyUI on module load
if __name__ == "__main__":
    # Start ComfyUI in background thread
    def init_comfyui():
        try:
            start_comfyui()
        except Exception as e:
            print(f"Failed to start ComfyUI: {e}")
            # Don't fail completely - handler will try to start on first request
    
    init_thread = threading.Thread(target=init_comfyui, daemon=True)
    init_thread.start()
    
    # Give ComfyUI some time to start
    time.sleep(5)
    
    # Start RunPod serverless worker
    runpod.serverless.start({"handler": handler})

