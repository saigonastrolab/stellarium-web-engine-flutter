import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mlastro_skymap/features/sky_map/data/sky_map_asset_loader.dart';
import 'package:mlastro_skymap/features/sky_map/data/sky_map_local_server.dart';
import 'package:mlastro_skymap/features/sky_map/logic/sky_map_cubit.dart';
import 'package:mlastro_skymap/utils/logger.dart';
import 'package:webview_windows/webview_windows.dart';

/// Chromium flags for WebView2 on Windows:
/// - `--ignore-gpu-blocklist --enable-webgl`: ensure WebGL is not disabled on
///   OEM hybrid-GPU (Intel/AMD iGPU + NVIDIA dGPU) laptop driver combinations.
/// - `--disable-features=CalculateNativeWinOcclusion` & backgrounding flags:
///   `webview_windows` parents its `ICoreWebView2CompositionController` to a
///   0x0 `HWND_MESSAGE` window; without these flags, Chromium's occlusion
///   tracker can mark the offscreen host as occluded and pause frame painting.
const _kWebView2AdditionalArgs =
    '--ignore-gpu-blocklist '
    '--enable-webgl '
    '--disable-features=CalculateNativeWinOcclusion '
    '--disable-background-timer-throttling '
    '--disable-renderer-backgrounding '
    '--disable-backgrounding-occluded-windows';

/// Windows desktop implementation of the Sky Map WebView host using Microsoft WebView2
/// (texture-backed direct DirectX surface via `webview_windows`).
class SkyMapWindowsWebView extends StatefulWidget {
  const SkyMapWindowsWebView({required this.cubit, super.key});

  final SkyMapCubit cubit;

  @override
  State<SkyMapWindowsWebView> createState() => _SkyMapWindowsWebViewState();
}

class _SkyMapWindowsWebViewState extends State<SkyMapWindowsWebView> {
  WebviewController? _controller;
  final _server = SkyMapLocalServer();
  StreamSubscription<dynamic>? _msgSub;
  StreamSubscription<LoadingState>? _loadingSub;
  String? _loadError;
  Timer? _readyWatchdog;

  @override
  void initState() {
    super.initState();
    unawaited(_initWebView());
  }

  @override
  void dispose() {
    _readyWatchdog?.cancel();
    _msgSub?.cancel();
    _loadingSub?.cancel();
    unawaited(_controller?.dispose());
    unawaited(_server.stop());
    super.dispose();
  }

  void _startReadyWatchdog(WebviewController controller) {
    _readyWatchdog?.cancel();
    _readyWatchdog = Timer(const Duration(seconds: 40), () async {
      if (!mounted || widget.cubit.isClosed || widget.cubit.state.mapReady) {
        return;
      }
      try {
        final jsReady = await controller.executeScript(
          'window.MlastroSky && window.MlastroSky.isReady()',
        );
        if (!mounted || widget.cubit.isClosed || widget.cubit.state.mapReady) {
          return;
        }
        xLog.e('SkyMap Windows: watchdog — map still not ready (js=$jsReady)');
        widget.cubit.onMapError(
          'Sky map loading timed out. Check %TEMP%\\mlastro_app.log for details.',
        );
      } catch (e, st) {
        xLog.e('SkyMap Windows: watchdog probe failed: $e\n$st');
      }
    });
  }

  static Future<void> _ensureEnvironmentInitialized() async {
    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: _kWebView2AdditionalArgs,
      );
      xLog.i('SkyMap Windows: WebView2 environment initialized with GPU/occlusion flags');
    } on PlatformException catch (e) {
      if (e.code != 'environment_already_initialized') {
        xLog.w('SkyMap Windows: initializeEnvironment warning: $e');
      }
    } catch (e) {
      xLog.w('SkyMap Windows: initializeEnvironment warning: $e');
    }
  }

  Future<void> _initWebView() async {
    WebviewController? controller;
    try {
      xLog.i('SkyMap Windows: checking WebView2 runtime');
      final version = await WebviewController.getWebViewVersion();
      if (!mounted) return;
      if (version == null) {
        throw StateError(
          'Microsoft Edge WebView2 Runtime is not installed on this PC.\n'
          'Please install WebView2 Runtime to view the Sky Map.',
        );
      }
      xLog.i('SkyMap Windows: WebView2 version: $version');

      final root = await SkyMapAssetLoader.ensureInstalled();
      if (!mounted) return;
      final baseUrl = await _server.start(root);
      if (!mounted) {
        await _server.stop();
        return;
      }
      xLog.i('SkyMap Windows: local server at $baseUrl (root=$root)');

      await _ensureEnvironmentInitialized();
      if (!mounted) {
        await _server.stop();
        return;
      }

      controller = WebviewController();
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        await _server.stop();
        return;
      }
      await controller.setBackgroundColor(const Color(0xFF060913));
      if (!mounted) {
        unawaited(controller.dispose());
        await _server.stop();
        return;
      }

      _msgSub = controller.webMessage.listen(_onWebMessage);
      _loadingSub = controller.loadingState.listen((loadingState) {
        if (loadingState == LoadingState.navigationCompleted) {
          xLog.i('SkyMap Windows: navigation completed');
        }
      });

      widget.cubit.attachWebController(
        WindowsWebviewControllerAdapter(controller),
      );
      _startReadyWatchdog(controller);

      // Mount controller into the widget tree and wait for its post-frame
      // callback (`_reportSurfaceSize` -> `SetSurfaceSize` + `texture_bridge_->Start()`)
      // to complete before loading the page so WebView2 bounds and frame capture
      // are active when Stellarium initializes WebGL.
      setState(() => _controller = controller);
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      if (!mounted) return;
      await controller.loadUrl('${baseUrl}index.html');
    } catch (e, st) {
      xLog.e('SkyMap Windows: WebView2 init failed: $e\n$st');
      if (_controller == null &&
          controller != null &&
          controller.value.isInitialized) {
        unawaited(controller.dispose());
      }
      if (mounted) {
        setState(() => _loadError = e.toString());
        if (!widget.cubit.isClosed) {
          widget.cubit.onMapError('Sky map Windows init failed: $e');
        }
      }
    }
  }

  void _onWebMessage(dynamic raw) {
    try {
      dynamic parsed = raw;
      if (parsed is String) {
        try {
          parsed = jsonDecode(parsed);
        } catch (_) {}
      }
      if (parsed is String) {
        try {
          parsed = jsonDecode(parsed);
        } catch (_) {}
      }
      if (parsed is! Map) {
        xLog.w('SkyMap Windows: unexpected web message: $raw');
        return;
      }
      final Map<dynamic, dynamic> decoded = parsed;

      final type = decoded['type']?.toString();
      final payload = decoded['payload'];

      switch (type) {
        case 'ready':
          _readyWatchdog?.cancel();
          xLog.i('SkyMap JS (Win): ready');
          unawaited(widget.cubit.onMapReady());
        case 'diag':
          if (payload != null) {
            xLog.i('SkyMap JS (Win) [diag]: $payload');
          }
        case 'reloading':
          xLog.w('SkyMap JS (Win): reloading WebView ($payload)');
        case 'log':
          if (payload != null) {
            xLog.d('SkyMap JS (Win): $payload');
          }
        case 'select':
          if (payload is Map) {
            widget.cubit.onObjectSelected(Map<String, dynamic>.from(payload));
          }
        case 'long_press':
          if (payload is Map) {
            widget.cubit.onSkyPointLongPress(Map<String, dynamic>.from(payload));
          }
        case 'limit_line_tap':
          if (payload is Map) {
            widget.cubit.onLimitLineTap(Map<String, dynamic>.from(payload));
          }
        case 'user_pan':
          widget.cubit.onUserPan();
        case 'follow_telescope_changed':
          if (payload is bool) {
            widget.cubit.onFollowTelescopeChanged(payload);
          }
        case 'key_down':
          if (payload is Map) {
            widget.cubit.onKeyDown(Map<String, dynamic>.from(payload));
          }
        case 'error':
          if (payload != null) {
            final msg = payload.toString();
            xLog.e('SkyMap JS (Win) error: $msg');
            widget.cubit.onMapError(msg);
          }
      }
    } catch (e, st) {
      xLog.e('SkyMap Windows: bridge message error: $e\nraw=$raw\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _loadError!,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF060913));
    }

    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kMiddleMouseButton) {
          unawaited(widget.cubit.resetToZenithOverview());
        }
      },
      child: Webview(controller),
    );
  }
}
