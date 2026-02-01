# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyobjc-framework-Cocoa",
#     "pyobjc-framework-Quartz",
#     "sounddevice",
#     "aiohttp",
# ]
# ///
#
# =============================================================================
# Seedling - Seed ASR 语音识别参考实现
# =============================================================================
#
# 这是一个持久化运行的守护进程，通过 HTTP API 提供语音识别服务。
# 由 macOS launchd 管理，开机自启、崩溃自动重启。
#
# LaunchAgent 配置文件:
#   ~/Library/LaunchAgents/com.panwenbo.seedling.plist
#
# 管理命令:
#   launchctl list | grep seedling          # 查看状态
#   launchctl unload ~/Library/LaunchAgents/com.panwenbo.seedling.plist  # 停止
#   launchctl load ~/Library/LaunchAgents/com.panwenbo.seedling.plist    # 启动
#
# HTTP API (端口 18888，可通过 SEEDLING_DAEMON_PORT 环境变量修改):
#   GET/POST /toggle  - 切换录音状态（推荐用这个）
#   GET/POST /start   - 开始录音
#   GET/POST /stop    - 停止录音并粘贴
#   GET/POST /cancel  - 取消录音
#   GET      /status  - 查看状态
#   GET      /health  - 健康检查
#   GET/POST /reload  - 热加载脚本（开发用）
#
# 日志文件:
#   /tmp/seedling.log          # 应用日志
#   /tmp/seedling.stdout.log   # 标准输出
#   /tmp/seedling.stderr.log   # 标准错误
#
# =============================================================================

import objc
import sounddevice as sd
import subprocess
import asyncio
import aiohttp
import threading
import gzip
import json
import struct
import os
import uuid
import queue
import numpy as np
from AppKit import (
    NSApplication,
    NSWindow,
    NSBackingStoreBuffered,
    NSButton,
    NSBezelStyleRounded,
    NSTextField,
    NSFont,
    NSFontAttributeName,
    NSPasteboard,
    NSStringPboardType,
    NSWindowStyleMaskTitled,
    NSWindowStyleMaskFullSizeContentView,
    NSWindowTitleHidden,
    NSApplicationActivationPolicyAccessory,
    NSApp,
    NSFloatingWindowLevel,
    NSEventModifierFlagCommand,
    NSTimer,
    NSEvent,
    NSScreen,
    NSColor,
    NSViewWidthSizable,
    NSViewHeightSizable,
    NSView,
    NSBezierPath,
    NSWorkspace,
    NSApplicationActivateIgnoringOtherApps,
)
from Foundation import NSObject, NSMakeRect, NSString, NSClassFromString
from PyObjCTools import AppHelper
from aiohttp import web


# HTTP Server Configuration
DEFAULT_PORT = 18888


class HTTPServerThread:
    """Run aiohttp web server in a background thread with its own event loop."""

    def __init__(self, delegate, port=None):
        self.delegate = delegate
        self.port = port or int(os.environ.get("DOUBAO_DAEMON_PORT", DEFAULT_PORT))
        self.thread = None
        self.loop = None
        self.runner = None
        self.site = None

    def start(self):
        """Start the HTTP server in a background thread."""
        self.thread = threading.Thread(target=self._run_server, daemon=True)
        self.thread.start()
        log(f"HTTP server starting on port {self.port}")

    def _run_server(self):
        """Run the aiohttp server in its own event loop."""
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)

        app = web.Application()
        # Support both GET and POST for all action endpoints
        app.router.add_route('*', '/start', self._handle_start)
        app.router.add_route('*', '/stop', self._handle_stop)
        app.router.add_route('*', '/cancel', self._handle_cancel)
        app.router.add_route('*', '/toggle', self._handle_toggle)
        app.router.add_route('*', '/status', self._handle_status)
        app.router.add_route('*', '/health', self._handle_health)
        app.router.add_route('*', '/reload', self._handle_reload)

        self.loop.run_until_complete(self._start_app(app))
        try:
            self.loop.run_forever()
        finally:
            self.loop.run_until_complete(self._cleanup())
            self.loop.close()

    async def _start_app(self, app):
        """Start the web application."""
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, 'localhost', self.port)
        await self.site.start()
        log(f"HTTP server listening on http://localhost:{self.port}")

    async def _cleanup(self):
        """Cleanup the web application."""
        if self.runner:
            await self.runner.cleanup()

    def _dispatch_to_main_thread(self, selector):
        """Dispatch a selector to the main thread for UI operations."""
        self.delegate.performSelectorOnMainThread_withObject_waitUntilDone_(
            selector, None, False
        )

    async def _handle_start(self, request):
        """GET/POST /start - Show window and begin recording."""
        log("HTTP: /start received")
        if self.delegate.is_recording:
            return web.json_response({
                "status": "already_recording",
                "message": "Recording is already in progress"
            }, status=409)
        self._dispatch_to_main_thread("triggerStartRecording:")
        return web.json_response({
            "status": "started",
            "message": "Recording started"
        })

    async def _handle_stop(self, request):
        """GET/POST /stop - Stop recording, copy text, paste, hide window."""
        log("HTTP: /stop received")
        if not self.delegate.is_recording:
            # Return last recording result if available
            return web.json_response({
                "status": "not_recording",
                "text": self.delegate.last_recording_text,
                "duration": round(self.delegate.last_recording_duration, 2),
                "message": "No recording in progress"
            })

        # Set up event to wait for result
        self.delegate._result_event = threading.Event()
        self.delegate._result_data = None

        self._dispatch_to_main_thread("triggerStopRecording:")

        # Wait for result with timeout (up to 5 seconds for ASR to finish)
        await asyncio.get_event_loop().run_in_executor(
            None, lambda: self.delegate._result_event.wait(timeout=5.0)
        )

        result = self.delegate._result_data or {}
        self.delegate._result_event = None
        self.delegate._result_data = None

        return web.json_response({
            "status": "stopped",
            "text": result.get("text", ""),
            "duration": result.get("duration", 0),
            "chars": result.get("chars", 0)
        })

    async def _handle_cancel(self, request):
        """GET/POST /cancel - Cancel recording, hide window (no paste)."""
        log("HTTP: /cancel received")
        if not self.delegate.is_recording:
            return web.json_response({
                "status": "not_recording",
                "message": "No recording in progress"
            })

        # Set up event to wait for result
        self.delegate._result_event = threading.Event()
        self.delegate._result_data = None

        self._dispatch_to_main_thread("triggerCancelRecording:")

        # Wait for result with timeout
        await asyncio.get_event_loop().run_in_executor(
            None, lambda: self.delegate._result_event.wait(timeout=2.0)
        )

        result = self.delegate._result_data or {}
        self.delegate._result_event = None
        self.delegate._result_data = None

        return web.json_response({
            "status": "cancelled",
            "duration": result.get("duration", 0),
            "message": "Recording cancelled"
        })

    async def _handle_toggle(self, request):
        """GET/POST /toggle - Toggle recording: start if not recording, stop if recording."""
        log("HTTP: /toggle received")
        if not self.delegate.is_recording:
            # Not recording -> start
            self._dispatch_to_main_thread("triggerStartRecording:")
            return web.json_response({
                "status": "started",
                "action": "start",
                "message": "Recording started"
            })
        else:
            # Recording -> stop and return result
            self.delegate._result_event = threading.Event()
            self.delegate._result_data = None

            self._dispatch_to_main_thread("triggerStopRecording:")

            # Wait for result with timeout
            await asyncio.get_event_loop().run_in_executor(
                None, lambda: self.delegate._result_event.wait(timeout=5.0)
            )

            result = self.delegate._result_data or {}
            self.delegate._result_event = None
            self.delegate._result_data = None

            return web.json_response({
                "status": "stopped",
                "action": "stop",
                "text": result.get("text", ""),
                "duration": result.get("duration", 0),
                "chars": result.get("chars", 0)
            })

    async def _handle_status(self, request):
        """GET /status - Get current state."""
        import time
        response = {
            "recording": self.delegate.is_recording,
            "text": self.delegate.recognized_text or "",
        }
        # Add duration if currently recording
        if self.delegate.is_recording and self.delegate.recording_start_time:
            response["duration"] = round(time.time() - self.delegate.recording_start_time, 2)
        # Add last recording info if not recording
        if not self.delegate.is_recording:
            response["last_text"] = self.delegate.last_recording_text
            response["last_duration"] = round(self.delegate.last_recording_duration, 2)
        return web.json_response(response)

    async def _handle_health(self, request):
        """GET /health - Health check."""
        return web.json_response({
            "status": "ok",
            "port": self.port,
            "recording": self.delegate.is_recording
        })

    async def _handle_reload(self, request):
        """GET/POST /reload - Hot reload the script."""
        import sys
        log("HTTP: /reload received - restarting process")

        # Schedule the reload after returning the response
        def do_reload():
            import time
            time.sleep(0.1)  # Small delay to allow response to be sent
            log("Reloading script...")
            # Get the original command used to start the script
            python = sys.executable
            script = os.path.abspath(__file__)
            os.execv(python, [python, script])

        threading.Thread(target=do_reload, daemon=True).start()

        return web.json_response({
            "status": "reloading",
            "message": "Script will reload in ~100ms"
        })


# ASR Protocol Constants
class ProtocolVersion:
    V1 = 0b0001

class MessageType:
    CLIENT_FULL_REQUEST = 0b0001
    CLIENT_AUDIO_ONLY_REQUEST = 0b0010
    SERVER_FULL_RESPONSE = 0b1001
    SERVER_ERROR_RESPONSE = 0b1111

class MessageTypeSpecificFlags:
    NO_SEQUENCE = 0b0000
    POS_SEQUENCE = 0b0001
    NEG_SEQUENCE = 0b0010
    NEG_WITH_SEQUENCE = 0b0011

class SerializationType:
    NO_SERIALIZATION = 0b0000
    JSON = 0b0001

class CompressionType:
    GZIP = 0b0001


# ASR Configuration
ASR_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
SAMPLE_RATE = 16000
SEGMENT_DURATION_MS = 200


class AsrRequestHeader:
    def __init__(self):
        self.message_type = MessageType.CLIENT_FULL_REQUEST
        self.message_type_specific_flags = MessageTypeSpecificFlags.POS_SEQUENCE
        self.serialization_type = SerializationType.JSON
        self.compression_type = CompressionType.GZIP
        self.reserved_data = bytes([0x00])

    def with_message_type(self, message_type):
        self.message_type = message_type
        return self

    def with_message_type_specific_flags(self, flags):
        self.message_type_specific_flags = flags
        return self

    def to_bytes(self):
        header = bytearray()
        header.append((ProtocolVersion.V1 << 4) | 1)
        header.append((self.message_type << 4) | self.message_type_specific_flags)
        header.append((self.serialization_type << 4) | self.compression_type)
        header.extend(self.reserved_data)
        return bytes(header)


class RequestBuilder:
    @staticmethod
    def new_auth_headers():
        app_key = os.environ.get("DOUBAO_APP_KEY", "3254061168")
        access_key = os.environ.get("DOUBAO_ACCESS_KEY", "1jFY86tc4aNrg-8K69dIM43HSjJ_jhyb")
        reqid = str(uuid.uuid4())
        return {
            "X-Api-Resource-Id": "volc.seedasr.sauc.duration",  # 2.0 version
            "X-Api-Request-Id": reqid,
            "X-Api-Access-Key": access_key,
            "X-Api-App-Key": app_key
        }

    @staticmethod
    def new_full_client_request(seq):
        header = AsrRequestHeader()
        header.with_message_type_specific_flags(MessageTypeSpecificFlags.POS_SEQUENCE)

        payload = {
            "user": {"uid": "doubaovoice_user"},
            "audio": {
                "format": "pcm",
                "codec": "raw",
                "rate": SAMPLE_RATE,
                "bits": 16,
                "channel": 1
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": True,
                "enable_punc": True,
                "enable_ddc": True,
                "show_utterances": True,
                "enable_nonstream": True,  # Two-pass recognition: realtime + final high-accuracy
                "end_window_size": 3000    # Trigger second pass after 3s silence
            }
        }

        payload_bytes = json.dumps(payload).encode('utf-8')
        compressed_payload = gzip.compress(payload_bytes)
        payload_size = len(compressed_payload)

        request = bytearray()
        request.extend(header.to_bytes())
        request.extend(struct.pack('>i', seq))
        request.extend(struct.pack('>I', payload_size))
        request.extend(compressed_payload)

        return bytes(request)

    @staticmethod
    def new_audio_only_request(seq, segment, is_last=False):
        header = AsrRequestHeader()
        if is_last:
            header.with_message_type_specific_flags(MessageTypeSpecificFlags.NEG_WITH_SEQUENCE)
            seq = -seq
        else:
            header.with_message_type_specific_flags(MessageTypeSpecificFlags.POS_SEQUENCE)
        header.with_message_type(MessageType.CLIENT_AUDIO_ONLY_REQUEST)

        request = bytearray()
        request.extend(header.to_bytes())
        request.extend(struct.pack('>i', seq))

        compressed_segment = gzip.compress(segment)
        request.extend(struct.pack('>I', len(compressed_segment)))
        request.extend(compressed_segment)

        return bytes(request)


class AsrResponse:
    def __init__(self):
        self.code = 0
        self.is_last_package = False
        self.payload_sequence = 0
        self.payload_msg = None


class ResponseParser:
    @staticmethod
    def parse_response(msg):
        response = AsrResponse()

        header_size = msg[0] & 0x0f
        message_type = msg[1] >> 4
        message_type_specific_flags = msg[1] & 0x0f
        serialization_method = msg[2] >> 4
        message_compression = msg[2] & 0x0f

        payload = msg[header_size * 4:]

        if message_type_specific_flags & 0x01:
            response.payload_sequence = struct.unpack('>i', payload[:4])[0]
            payload = payload[4:]
        if message_type_specific_flags & 0x02:
            response.is_last_package = True
        if message_type_specific_flags & 0x04:
            payload = payload[4:]

        if message_type == MessageType.SERVER_FULL_RESPONSE:
            response.payload_size = struct.unpack('>I', payload[:4])[0]
            payload = payload[4:]
        elif message_type == MessageType.SERVER_ERROR_RESPONSE:
            response.code = struct.unpack('>i', payload[:4])[0]
            response.payload_size = struct.unpack('>I', payload[4:8])[0]
            payload = payload[8:]

        if not payload:
            return response

        if message_compression == CompressionType.GZIP:
            try:
                payload = gzip.decompress(payload)
            except Exception:
                return response

        try:
            if serialization_method == SerializationType.JSON:
                response.payload_msg = json.loads(payload.decode('utf-8'))
        except Exception:
            pass

        return response


def strip_trailing_punctuation(text):
    """Remove trailing punctuation (half-width and full-width)"""
    punctuation = '.,!?;:。，！？；：、…~～'
    return text.rstrip(punctuation)


def log(msg):
    """Write to log file for debugging"""
    import datetime
    timestamp = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{timestamp}] {msg}"
    print(line)
    try:
        with open("/tmp/doubaovoice.log", "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# Liquid Glass Material Variants (macOS 26+ private API)
class GlassVariant:
    Regular = 0
    Sidebar = 1
    Header = 2
    Inspector = 3
    Widgets = 4
    Sheet = 5
    HUD = 6
    Popover = 7
    WindowBackground = 8
    Menu = 9
    FullscreenUI = 10
    ControlCenter = 11
    Tooltip = 12


def create_glass_effect_view(frame, variant=GlassVariant.Popover):
    """
    Create a Liquid Glass effect view (macOS 26+).

    Args:
        frame: NSRect for the view frame
        variant: GlassVariant enum value

    Returns:
        NSGlassEffectView instance
    """
    from AppKit import NSView
    from Quartz import CGColorCreateGenericGray

    GlassEffectView = NSClassFromString("NSGlassEffectView")
    glass = GlassEffectView.alloc().initWithFrame_(frame)
    glass.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)

    # Set variant using KVC (private property)
    try:
        glass.setValue_forKey_(variant, "_variant")
    except Exception as e:
        log(f"Failed to set variant: {e}")

    # Set larger corner radius for modern look
    glass.setWantsLayer_(True)
    if glass.layer():
        glass.layer().setCornerRadius_(28.0)
        glass.layer().setMasksToBounds_(True)

    # Add gray tint layer inside glass view
    tint = NSView.alloc().initWithFrame_(frame)
    tint.setWantsLayer_(True)
    tint.layer().setBackgroundColor_(CGColorCreateGenericGray(0.9, 0.7))
    tint.layer().setCornerRadius_(28.0)
    tint.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
    glass.addSubview_(tint)

    return glass


class RealtimeASRClient:
    def __init__(self, on_text_callback):
        self.on_text_callback = on_text_callback
        self.audio_queue = queue.Queue()
        self.running = False
        self.thread = None
        self.loop = None
        self._ws = None
        self._tasks = []  # Store task references for cancellation

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._run_async_loop, daemon=True)
        self.thread.start()

    def finish(self, timeout=1.5):
        """Graceful stop: send final packet and wait for result with timeout"""
        log("finish: starting graceful shutdown")
        self.audio_queue.put(None)  # Trigger sending final packet

        # Wait for thread to finish (exits after receiving is_last_package)
        if self.thread and self.thread.is_alive():
            log(f"finish: waiting for thread (timeout={timeout}s)")
            self.thread.join(timeout=timeout)

        if self.thread and self.thread.is_alive():
            log("finish: thread timeout, forcing close")
            self._force_close()
        else:
            log("finish: thread finished normally")

    def _force_close(self):
        """Force close all resources"""
        self.running = False

        # Cancel all async tasks
        if self._tasks and self.loop and self.loop.is_running():
            log(f"finish: cancelling {len(self._tasks)} tasks")
            for task in self._tasks:
                if not task.done():
                    self.loop.call_soon_threadsafe(task.cancel)

        # Close WebSocket connection
        if self._ws and self.loop and self.loop.is_running():
            log("finish: closing WebSocket")
            try:
                asyncio.run_coroutine_threadsafe(self._ws.close(), self.loop)
            except Exception:
                pass

        # Wait a bit for thread cleanup
        if self.thread and self.thread.is_alive():
            log("finish: waiting for cleanup (timeout=0.3s)")
            self.thread.join(timeout=0.3)
            if self.thread.is_alive():
                log("finish: warning - thread still alive, giving up")
            else:
                log("finish: thread finished")

    def stop(self):
        """Force stop: close connection immediately"""
        self.running = False
        self.audio_queue.put(None)  # Signal to stop
        # Force close WebSocket connection
        if self._ws and self.loop:
            try:
                asyncio.run_coroutine_threadsafe(self._ws.close(), self.loop)
            except Exception:
                pass
        # Wait for thread with timeout to avoid blocking
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=0.5)

    def feed_audio(self, audio_bytes):
        if self.running:
            self.audio_queue.put(audio_bytes)

    def _run_async_loop(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_until_complete(self._asr_session())
        except Exception as e:
            print(f"ASR error: {e}")
        finally:
            self.loop.close()

    async def _asr_session(self):
        headers = RequestBuilder.new_auth_headers()
        seq = 1
        log("asr_session: connecting")

        async with aiohttp.ClientSession() as session:
            try:
                async with session.ws_connect(ASR_URL, headers=headers) as ws:
                    self._ws = ws
                    log("asr_session: WebSocket connected")

                    # Send full client request
                    request = RequestBuilder.new_full_client_request(seq)
                    seq += 1
                    await ws.send_bytes(request)

                    # Wait for initial response
                    msg = await ws.receive()
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        ResponseParser.parse_response(msg.data)
                    log("asr_session: initialized, starting send/receive tasks")

                    # Start sender and receiver tasks
                    sender_task = asyncio.create_task(self._send_audio(ws, seq))
                    receiver_task = asyncio.create_task(self._receive_responses(ws))
                    self._tasks = [sender_task, receiver_task]

                    try:
                        await asyncio.gather(sender_task, receiver_task)
                    except asyncio.CancelledError:
                        log("asr_session: tasks cancelled")
                    log("asr_session: send/receive tasks ended")

            except asyncio.CancelledError:
                log("asr_session: session cancelled")
            except Exception as e:
                if self.running:
                    log(f"asr_session: WebSocket error - {e}")
            finally:
                self._ws = None
                self._tasks = []
                log("asr_session: session ended")

    async def _send_audio(self, ws, seq):
        buffer = bytearray()
        segment_size = SAMPLE_RATE * 2 * SEGMENT_DURATION_MS // 1000  # 6400 bytes
        log("send_audio: starting")

        while self.running:
            try:
                audio_data = await asyncio.wait_for(
                    asyncio.get_event_loop().run_in_executor(
                        None, lambda: self.audio_queue.get(timeout=0.1)
                    ),
                    timeout=0.3
                )

                if audio_data is None:  # Stop signal
                    log("send_audio: received stop signal")
                    break

                buffer.extend(audio_data)

                while len(buffer) >= segment_size:
                    segment = bytes(buffer[:segment_size])
                    buffer = buffer[segment_size:]

                    request = RequestBuilder.new_audio_only_request(seq, segment, is_last=False)
                    await asyncio.wait_for(ws.send_bytes(request), timeout=2.0)
                    seq += 1

            except asyncio.TimeoutError:
                continue
            except asyncio.CancelledError:
                log("send_audio: task cancelled")
                return
            except queue.Empty:
                continue
            except Exception as e:
                log(f"send_audio: exception - {e}")
                break

        # Send remaining buffer as last packet
        log(f"send_audio: sending final packet (buffer={len(buffer)} bytes)")
        try:
            if buffer:
                request = RequestBuilder.new_audio_only_request(seq, bytes(buffer), is_last=True)
            else:
                request = RequestBuilder.new_audio_only_request(seq, b'', is_last=True)
            await asyncio.wait_for(ws.send_bytes(request), timeout=2.0)
            log("send_audio: final packet sent")
        except Exception as e:
            log(f"send_audio: failed to send final packet - {e}")

    async def _receive_responses(self, ws):
        log("receive: starting")
        try:
            while self.running:
                try:
                    msg = await asyncio.wait_for(ws.receive(), timeout=0.3)
                except asyncio.TimeoutError:
                    continue
                except asyncio.CancelledError:
                    log("receive: task cancelled")
                    return

                if msg.type == aiohttp.WSMsgType.BINARY:
                    response = ResponseParser.parse_response(msg.data)

                    if response.payload_msg and 'result' in response.payload_msg:
                        text = response.payload_msg['result'].get('text', '')
                        if text and self.on_text_callback:
                            self.on_text_callback(text)

                    if response.is_last_package:
                        log("receive: got is_last_package")
                        break
                    if response.code != 0:
                        log(f"receive: got error code {response.code}")
                        break

                elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSED):
                    log(f"receive: WebSocket closed/error - {msg.type}")
                    break

            log("receive: loop ended")
        except asyncio.CancelledError:
            log("receive: task cancelled (outer)")
        except Exception as e:
            log(f"receive: exception - {e}")


class AudioRecorderDelegate(NSObject):
    def init(self):
        self = objc.super(AudioRecorderDelegate, self).init()
        if self is None:
            return None
        self.is_recording = False
        self.sample_rate = SAMPLE_RATE
        self.stream = None
        self.asr_client = None
        self.recognized_text = ""
        self.window = None
        # For tracking recording duration
        self.recording_start_time = None
        self.last_recording_duration = 0.0
        self.last_recording_text = ""
        # For async result notification
        self._result_event = None
        self._result_data = None
        # For restoring focus after recording
        self._previous_app = None
        return self

    def setWindow_(self, window):
        self.window = window

    def resetForNewSession(self):
        """Reset state for a new recording session."""
        self.is_recording = False
        self.recognized_text = ""
        self.asr_client = None
        self.stream = None
        if self.window:
            self.window.resetUI()

    def triggerStartRecording_(self, _sender):
        """Entry point from HTTP - show window and start recording."""
        log("triggerStartRecording: called")
        if self.is_recording:
            log("triggerStartRecording: already recording, ignoring")
            return
        self._showWindowAndStartRecording()

    def triggerStopRecording_(self, _sender):
        """Entry point from HTTP - stop recording with paste."""
        log("triggerStopRecording: called")
        self.stopRecording_(None)

    def triggerCancelRecording_(self, _sender):
        """Entry point from HTTP - cancel recording without paste."""
        log("triggerCancelRecording: called")
        self.cancelRecording_(None)

    def _showWindowAndStartRecording(self):
        """Show the window and start recording."""
        log("_showWindowAndStartRecording: starting")
        # Save the currently focused app to restore later
        self._previous_app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if self._previous_app:
            log(f"_showWindowAndStartRecording: saved previous app: {self._previous_app.localizedName()}")
        self.resetForNewSession()
        if self.window:
            self.window.showAndPosition()
        NSApp.activateIgnoringOtherApps_(True)
        self.startRecording()

    def _hideWindow(self):
        """Hide the window after recording and restore focus to previous app."""
        if self.window:
            self.window.orderOut_(None)
        # Restore focus to the previous app
        if self._previous_app:
            log(f"_hideWindow: restoring focus to {self._previous_app.localizedName()}")
            self._previous_app.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
            self._previous_app = None

    def onTextReceived_(self, text):
        self.recognized_text = text
        if self.window:
            self.window.performSelectorOnMainThread_withObject_waitUntilDone_(
                "updateText:", text, False
            )

    def startRecording(self):
        import time
        self.is_recording = True
        self.recognized_text = ""
        self.recording_start_time = time.time()

        # Start ASR client
        self.asr_client = RealtimeASRClient(self.onTextReceived_)
        self.asr_client.start()

        def callback(indata, _frames, _time_info, _status):
            if self.is_recording and self.asr_client:
                # Convert to bytes and feed to ASR
                audio_bytes = indata.tobytes()
                self.asr_client.feed_audio(audio_bytes)

                # Send waveform data to UI (on main thread)
                if self.window and hasattr(self.window, 'waveform_view'):
                    samples = np.frombuffer(audio_bytes, dtype=np.int16)
                    self.window.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "updateWaveform:", samples, False
                    )

        self.stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype='int16',
            callback=callback
        )
        self.stream.start()

    def stopRecording_(self, _sender):
        """Stop recording, copy text, paste, and hide window."""
        import time
        if not self.is_recording:
            return
        log("stopRecording: starting")
        self.is_recording = False

        # Calculate duration
        if self.recording_start_time:
            self.last_recording_duration = time.time() - self.recording_start_time
        else:
            self.last_recording_duration = 0.0

        if self.window:
            self.window.stopPulse()

        if self.stream:
            log("stopRecording: stopping audio stream")
            # Close stream in background thread to avoid blocking
            stream_to_close = self.stream
            self.stream = None
            def close_stream():
                try:
                    stream_to_close.stop()
                    stream_to_close.close()
                    log("stopRecording: audio stream closed")
                except Exception as e:
                    log(f"stopRecording: error closing stream - {e}")
            threading.Thread(target=close_stream, daemon=True).start()

        if self.asr_client:
            log("stopRecording: calling asr_client.finish()")
            self.asr_client.finish()
            self.asr_client = None
            log("stopRecording: asr_client.finish() returned")

        # Copy recognized text to clipboard (strip trailing punctuation)
        text_to_paste = strip_trailing_punctuation(self.recognized_text) if self.recognized_text else ""
        self.last_recording_text = text_to_paste
        pasteboard = NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        pasteboard.setString_forType_(text_to_paste, NSStringPboardType)
        log(f"stopRecording: copied text ({len(text_to_paste)} chars)")

        # Hide window first
        self._hideWindow()

        # Paste after hiding using AppleScript (run in background shell)
        subprocess.Popen(
            'sleep 0.05 && osascript -e \'tell application "System Events" to keystroke "v" using command down\'',
            shell=True
        )

        # Signal completion for HTTP handlers
        if self._result_event:
            self._result_data = {
                "text": text_to_paste,
                "duration": round(self.last_recording_duration, 2),
                "chars": len(text_to_paste)
            }
            self._result_event.set()

        log("stopRecording: done")

    def cancelRecording_(self, _sender):
        """Stop recording and hide window without copying/pasting."""
        import time
        log("cancelRecording: starting")
        self.is_recording = False

        # Calculate duration
        if self.recording_start_time:
            self.last_recording_duration = time.time() - self.recording_start_time
        else:
            self.last_recording_duration = 0.0
        self.last_recording_text = ""

        if self.window:
            self.window.stopPulse()

        if self.stream:
            # Close stream in background thread to avoid blocking
            stream_to_close = self.stream
            self.stream = None
            def close_stream():
                try:
                    stream_to_close.stop()
                    stream_to_close.close()
                except Exception:
                    pass
            threading.Thread(target=close_stream, daemon=True).start()

        if self.asr_client:
            self.asr_client.stop()
            self.asr_client = None

        self._hideWindow()

        # Signal completion for HTTP handlers
        if self._result_event:
            self._result_data = {
                "text": "",
                "duration": round(self.last_recording_duration, 2),
                "cancelled": True
            }
            self._result_event.set()

        log("cancelRecording: done")

    def copyText_(self, _sender):
        text_to_copy = self.recognized_text if self.recognized_text else ""
        pasteboard = NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        pasteboard.setString_forType_(text_to_copy, NSStringPboardType)


class WaveformView(NSView):
    """Custom NSView for drawing real-time audio waveform animation"""

    def initWithFrame_(self, frame):
        self = objc.super(WaveformView, self).initWithFrame_(frame)
        if self is None:
            return None

        # Waveform data buffer (stores amplitude values for visualization)
        self.buffer_size = 10  # Fewer points for smoother, cleaner look
        self.amplitudes = np.zeros(self.buffer_size)
        self.display_amplitudes = np.zeros(self.buffer_size)  # Smoothed values for display
        self.lock = threading.Lock()

        # Noise gate threshold (ignore quiet sounds)
        self.noise_threshold = 0.025

        # Display amplification (applied directly to visual height)
        self.display_gain = 5.0

        # Animation timer (30fps for smoother appearance)
        self.animation_timer = None

        # Visual settings - darker professional gray tone
        self.waveform_color = NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.25, 0.25, 0.28, 1.0  # Darker gray, full opacity
        )

        return self

    def startAnimation(self):
        """Start the animation timer"""
        if self.animation_timer is None:
            self.animation_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                1.0 / 30.0, self, "animationTick:", None, True  # 30fps for smoother look
            )

    def stopAnimation(self):
        """Stop the animation timer"""
        if self.animation_timer:
            self.animation_timer.invalidate()
            self.animation_timer = None

    def resetWaveform(self):
        """Reset waveform buffers for a new recording session."""
        with self.lock:
            self.amplitudes = np.zeros(self.buffer_size)
            self.display_amplitudes = np.zeros(self.buffer_size)
        self.setNeedsDisplay_(True)

    def animationTick_(self, timer):
        """Called every frame to smoothly interpolate and redraw the waveform"""
        with self.lock:
            # Smooth interpolation: slowly move display values toward target values
            # Higher weight on old values = smoother, less jittery animation
            self.display_amplitudes = self.display_amplitudes * 0.85 + self.amplitudes * 0.15
        self.setNeedsDisplay_(True)

    def updateWithSamples_(self, samples):
        """Update the waveform buffer with new audio samples (thread-safe)"""
        if samples is None or len(samples) == 0:
            return

        # Calculate RMS amplitude for the entire audio chunk
        samples_float = samples.astype(np.float32)

        # Calculate a few sub-chunks for more detail
        num_new_points = 2  # Add 2 points per callback for slower, smoother scrolling
        chunk_size = len(samples) // num_new_points
        new_values = []

        for i in range(num_new_points):
            start = i * chunk_size
            end = min(start + chunk_size, len(samples))
            chunk = samples_float[start:end]
            chunk_rms = np.sqrt(np.mean(chunk ** 2)) / 32768.0

            # Apply noise gate: ignore values below threshold (visual filter only)
            if chunk_rms < self.noise_threshold:
                new_values.append(0.0)
            else:
                # Store normalized value (typical speech RMS ~0.01-0.1, multiply by 10 to get 0.1-1.0 range)
                new_values.append(chunk_rms * 10.0)

        with self.lock:
            # Scroll left: shift old values and append new ones on the right
            self.amplitudes = np.roll(self.amplitudes, -num_new_points)
            self.amplitudes[-num_new_points:] = new_values

    def drawRect_(self, rect):
        """Draw the waveform"""
        bounds = self.bounds()
        width = bounds.size.width
        height = bounds.size.height
        center_y = height / 2

        # Get smoothed display amplitudes thread-safely
        with self.lock:
            amps = self.display_amplitudes.copy()

        # Draw background (transparent)
        NSColor.clearColor().set()
        NSBezierPath.fillRect_(bounds)

        # Set waveform color
        self.waveform_color.set()

        # Create smooth waveform path
        path = NSBezierPath.bezierPath()
        path.setLineWidth_(2.0)

        # Calculate x positions
        x_step = width / (len(amps) - 1) if len(amps) > 1 else width

        # Draw upper curve (apply display_gain directly to visual height)
        max_amplitude = height / 2 - 4
        path.moveToPoint_((0, center_y))
        for i, amp in enumerate(amps):
            x = i * x_step
            y = center_y + min(amp * self.display_gain, 1.0) * max_amplitude
            if i == 0:
                path.lineToPoint_((x, y))
            else:
                # Use curve for smoother appearance
                prev_x = (i - 1) * x_step
                ctrl_x = (prev_x + x) / 2
                path.curveToPoint_controlPoint1_controlPoint2_(
                    (x, y),
                    (ctrl_x, path.currentPoint().y),
                    (ctrl_x, y)
                )

        # Draw lower curve (mirror)
        for i in range(len(amps) - 1, -1, -1):
            amp = amps[i]
            x = i * x_step
            y = center_y - min(amp * self.display_gain, 1.0) * max_amplitude
            if i == len(amps) - 1:
                path.lineToPoint_((x, y))
            else:
                next_x = (i + 1) * x_step
                ctrl_x = (next_x + x) / 2
                path.curveToPoint_controlPoint1_controlPoint2_(
                    (x, y),
                    (ctrl_x, path.currentPoint().y),
                    (ctrl_x, y)
                )

        path.closePath()

        # Fill with semi-transparent darker gray
        fill_color = NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.25, 0.25, 0.28, 0.4
        )
        fill_color.set()
        path.fill()

        # Stroke the outline
        self.waveform_color.set()
        path.stroke()


class RecorderWindow(NSWindow):
    def initWithDelegate_(self, delegate):
        # Layout constants
        self.waveform_width = 68  # Width of waveform area
        self.right_min_width = 280  # Min width for text + buttons area
        self.right_max_width = 500  # Max width for text + buttons area
        self.gap = 16  # Gap between waveform and right area
        self.padding = 16
        self.button_area_height = 45  # Height for buttons + gap above

        # Total window dimensions
        self.min_width = self.waveform_width + self.gap + self.right_min_width
        self.max_width = self.waveform_width + self.gap + self.right_max_width

        frame = NSMakeRect(0, 0, self.min_width, 80)
        style = NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
        self = objc.super(RecorderWindow, self).initWithContentRect_styleMask_backing_defer_(
            frame,
            style,
            NSBackingStoreBuffered,
            False
        )
        if self is None:
            return None

        self.setLevel_(NSFloatingWindowLevel)
        self.setTitlebarAppearsTransparent_(True)
        self.setTitleVisibility_(NSWindowTitleHidden)
        self.setMovableByWindowBackground_(True)

        # Make window fully transparent (glass view handles the appearance)
        self.setOpaque_(False)
        self.setBackgroundColor_(NSColor.clearColor())

        # Create glass effect view (Liquid Glass on macOS 26+, fallback to NSVisualEffectView)
        glass_view = create_glass_effect_view(self.contentView().bounds(), GlassVariant.Popover)
        self.setContentView_(glass_view)

        # Position window near mouse cursor
        self._positionNearMouse_(frame.size)

        # Text state
        self.current_text = ""

        # Waveform view (left side, vertically centered)
        self.waveform_height = 40  # Fixed height for waveform
        waveform_y = (80 - self.waveform_height) / 2  # Center vertically
        waveform_frame = NSMakeRect(self.padding, waveform_y, self.waveform_width - self.padding, self.waveform_height)
        self.waveform_view = WaveformView.alloc().initWithFrame_(waveform_frame)
        self.contentView().addSubview_(self.waveform_view)
        self.waveform_view.startAnimation()

        # Right side area starts after waveform + gap
        right_start_x = self.waveform_width + self.gap

        # Text display (right side, above buttons)
        text_x = right_start_x
        text_width = self.right_min_width - self.padding
        self.text_field = NSTextField.alloc().initWithFrame_(NSMakeRect(text_x, self.button_area_height, text_width, 20))
        self.text_field.setStringValue_("")
        self.text_field.setBezeled_(False)
        self.text_field.setDrawsBackground_(False)
        self.text_field.setEditable_(False)
        self.text_field.setSelectable_(True)
        self.text_field.setFont_(NSFont.systemFontOfSize_(14))
        self.contentView().addSubview_(self.text_field)

        # Buttons (right-aligned within right area)
        self.button_width = 75
        self.button_gap = 10
        total_buttons_width = self.button_width * 3 + self.button_gap * 2
        start_x = self.min_width - self.padding - total_buttons_width

        # Cancel button (ESC)
        self.cancel_button = NSButton.alloc().initWithFrame_(NSMakeRect(start_x, 10, self.button_width, 24))
        self.cancel_button.setTitle_("Cancel ⎋")
        self.cancel_button.setBezelStyle_(NSBezelStyleRounded)
        self.cancel_button.setTarget_(delegate)
        self.cancel_button.setAction_("cancelRecording:")
        self.cancel_button.setKeyEquivalent_("\x1b")  # ESC
        self.contentView().addSubview_(self.cancel_button)

        # Copy button (Cmd+C)
        self.copy_button = NSButton.alloc().initWithFrame_(NSMakeRect(start_x + self.button_width + self.button_gap, 10, self.button_width, 24))
        self.copy_button.setTitle_("Copy ⌘C")
        self.copy_button.setBezelStyle_(NSBezelStyleRounded)
        self.copy_button.setTarget_(delegate)
        self.copy_button.setAction_("copyText:")
        self.copy_button.setKeyEquivalent_("c")
        self.copy_button.setKeyEquivalentModifierMask_(NSEventModifierFlagCommand)
        self.contentView().addSubview_(self.copy_button)

        # Done button (Enter)
        self.stop_button = NSButton.alloc().initWithFrame_(NSMakeRect(start_x + (self.button_width + self.button_gap) * 2, 10, self.button_width, 24))
        self.stop_button.setTitle_("Done ⏎")
        self.stop_button.setBezelStyle_(NSBezelStyleRounded)
        self.stop_button.setTarget_(delegate)
        self.stop_button.setAction_("stopRecording:")
        self.stop_button.setKeyEquivalent_("\r")
        self.contentView().addSubview_(self.stop_button)

        return self

    def _positionNearMouse_(self, size):
        """Position window near mouse cursor, keeping it on screen"""
        mouse = NSEvent.mouseLocation()
        screen = NSScreen.mainScreen()
        if not screen:
            self.center()
            return

        screen_frame = screen.visibleFrame()

        # Offset from cursor (appear above-right of cursor)
        offset_x = 15
        offset_y = 15

        # Calculate initial position
        x = mouse.x + offset_x
        y = mouse.y + offset_y

        # Keep window within screen bounds
        if x + size.width > screen_frame.origin.x + screen_frame.size.width:
            # Flip to left of cursor if too far right
            x = mouse.x - offset_x - size.width
        if x < screen_frame.origin.x:
            x = screen_frame.origin.x

        if y + size.height > screen_frame.origin.y + screen_frame.size.height:
            # Flip to below cursor if too high
            y = mouse.y - offset_y - size.height
        if y < screen_frame.origin.y:
            y = screen_frame.origin.y

        self.setFrameOrigin_((x, y))

    def resetUI(self):
        """Reset UI for a new recording session."""
        # Clear text
        self.current_text = ""
        if self.text_field:
            self.text_field.setStringValue_("")

        # Reset window to minimum size
        self._resetToMinSize()

        # Reset waveform
        if hasattr(self, 'waveform_view') and self.waveform_view:
            self.waveform_view.resetWaveform()
            self.waveform_view.startAnimation()

    def _resetToMinSize(self):
        """Reset window to minimum size."""
        old_frame = self.frame()
        center_x = old_frame.origin.x + old_frame.size.width / 2
        center_y = old_frame.origin.y + old_frame.size.height / 2
        new_width = self.min_width
        new_height = 80  # Original min height
        new_x = center_x - new_width / 2
        new_y = center_y - new_height / 2
        new_frame = NSMakeRect(new_x, new_y, new_width, new_height)
        self.setFrame_display_animate_(new_frame, True, False)

        # Reset waveform view position
        waveform_y = (new_height - self.waveform_height) / 2
        self.waveform_view.setFrame_(NSMakeRect(self.padding, waveform_y, self.waveform_width - self.padding, self.waveform_height))

        # Reset text field position
        right_start_x = self.waveform_width + self.gap
        text_width = self.right_min_width - self.padding
        self.text_field.setFrame_(NSMakeRect(right_start_x, self.button_area_height, text_width, 20))

        # Reset button positions
        total_buttons_width = self.button_width * 3 + self.button_gap * 2
        start_x = new_width - self.padding - total_buttons_width
        self.cancel_button.setFrame_(NSMakeRect(start_x, 10, self.button_width, 24))
        self.copy_button.setFrame_(NSMakeRect(start_x + self.button_width + self.button_gap, 10, self.button_width, 24))
        self.stop_button.setFrame_(NSMakeRect(start_x + (self.button_width + self.button_gap) * 2, 10, self.button_width, 24))

    def showAndPosition(self):
        """Position window near mouse and show it."""
        self._positionNearMouse_(self.frame().size)
        self.makeKeyAndOrderFront_(None)

    def canBecomeKeyWindow(self):
        return True

    def canBecomeMainWindow(self):
        return True

    def mouseDown_(self, _event):
        self.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def stopPulse(self):
        # Stop waveform animation
        if hasattr(self, 'waveform_view') and self.waveform_view:
            self.waveform_view.stopAnimation()

    def updateText_(self, text):
        self.current_text = text
        self._refreshDisplay()

    def updateWaveform_(self, samples):
        """Update waveform view with audio samples (called from main thread)"""
        if hasattr(self, 'waveform_view') and self.waveform_view:
            self.waveform_view.updateWithSamples_(samples)

    def _refreshDisplay(self):
        if not self.text_field:
            return

        # Display text directly (waveform serves as the activity indicator)
        display_text = self.current_text if self.current_text else ""
        self.text_field.setStringValue_(display_text)

        # Calculate text size (for the right side area only)
        font = self.text_field.font()
        attrs = {NSFontAttributeName: font}
        text_size = NSString.stringWithString_(display_text).sizeWithAttributes_(attrs)

        # Right side area width constraints
        right_area_max_text_width = self.right_max_width - self.padding
        right_area_min_text_width = self.right_min_width - self.padding

        # Calculate text width within right area constraints
        text_width = min(max(text_size.width + 10, right_area_min_text_width), right_area_max_text_width)
        right_area_width = text_width + self.padding

        # For multi-line, estimate height (rough calculation)
        if text_size.width > text_width:
            lines = int(text_size.width / text_width) + 1
            text_height = text_size.height * lines
        else:
            text_height = text_size.height

        text_height = max(text_height, 20)
        new_height = text_height + self.button_area_height + self.padding

        # Total window width = waveform + gap + right area
        new_width = self.waveform_width + self.gap + right_area_width

        # Update window frame (keep center position)
        old_frame = self.frame()
        center_x = old_frame.origin.x + old_frame.size.width / 2
        center_y = old_frame.origin.y + old_frame.size.height / 2
        new_x = center_x - new_width / 2
        new_y = center_y - new_height / 2
        new_frame = NSMakeRect(new_x, new_y, new_width, new_height)
        self.setFrame_display_animate_(new_frame, True, True)

        # Update waveform view frame (left side, vertically centered with fixed height)
        waveform_y = (new_height - self.waveform_height) / 2
        self.waveform_view.setFrame_(NSMakeRect(self.padding, waveform_y, self.waveform_width - self.padding, self.waveform_height))

        # Update text field frame (right side)
        right_start_x = self.waveform_width + self.gap
        self.text_field.setFrame_(NSMakeRect(right_start_x, self.button_area_height, text_width, text_height))

        # Update button positions (right-aligned within window)
        total_buttons_width = self.button_width * 3 + self.button_gap * 2
        start_x = new_width - self.padding - total_buttons_width
        self.cancel_button.setFrame_(NSMakeRect(start_x, 10, self.button_width, 24))
        self.copy_button.setFrame_(NSMakeRect(start_x + self.button_width + self.button_gap, 10, self.button_width, 24))
        self.stop_button.setFrame_(NSMakeRect(start_x + (self.button_width + self.button_gap) * 2, 10, self.button_width, 24))


def main():
    import signal

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    delegate = AudioRecorderDelegate.alloc().init()
    window = RecorderWindow.alloc().initWithDelegate_(delegate)

    # Connect delegate and window
    delegate.setWindow_(window)

    # Don't show window on startup - it will be shown via HTTP /start
    # Don't start recording - wait for HTTP trigger

    # Start HTTP server in background thread
    http_server = HTTPServerThread(delegate)
    http_server.start()

    log(f"Daemon started. HTTP API on http://localhost:{http_server.port}")
    log("Endpoints: POST /start, POST /stop, POST /cancel, GET /status, GET /health")

    # Handle Ctrl+C and SIGTERM gracefully
    def signal_handler(sig, frame):
        log(f"Received signal {sig}, exiting...")
        # Use performSelectorOnMainThread to safely terminate from signal handler
        NSApp.performSelectorOnMainThread_withObject_waitUntilDone_(
            "terminate:", None, False
        )

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    AppHelper.runEventLoop()


if __name__ == "__main__":
    main()
