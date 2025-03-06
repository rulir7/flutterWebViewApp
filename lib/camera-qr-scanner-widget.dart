import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:typed_data';

class CameraWithQRScanner extends StatefulWidget {
  final Function(String) onQRCodeDetected;
  final Function(String) onPhotoTaken;

  const CameraWithQRScanner({
    Key? key,
    required this.onQRCodeDetected,
    required this.onPhotoTaken,
  }) : super(key: key);

  @override
  State<CameraWithQRScanner> createState() => _CameraWithQRScannerState();
}

class _CameraWithQRScannerState extends State<CameraWithQRScanner> {
  MobileScannerController? _controller;
  bool _isQRMode = true;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // Método para capturar uma foto e escanear QR Code
  Future<void> _capturePhoto() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(source: ImageSource.camera);

      if (photo != null) {
        // Salvar a imagem temporariamente
        final tempDir = await getTemporaryDirectory();
        final imagePath =
            '${tempDir.path}/image_${DateTime.now().millisecondsSinceEpoch}.jpg';

        // Converter bytes em arquivo
        await File(imagePath).writeAsBytes(await photo.readAsBytes());

        // Chamar o callback de foto
        widget.onPhotoTaken(imagePath);

        // Escanear QR Code na imagem
        final BarcodeCapture? capture =
            await _controller!.analyzeImage(photo.path);

        if (capture != null && capture.barcodes.isNotEmpty) {
          final String code = capture.barcodes.first.rawValue!;
          widget.onQRCodeDetected(code);
        }
      }
    } catch (e) {
      debugPrint('Erro ao capturar foto: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao capturar foto: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(_isQRMode ? 'Escanear QR Code / Tirar Foto' : 'Tirar Foto'),
        actions: [
          IconButton(
            icon: Icon(_isQRMode ? Icons.camera_alt : Icons.qr_code),
            onPressed: () {
              setState(() {
                _isQRMode = !_isQRMode;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller?.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios),
            onPressed: () => _controller?.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: (BarcodeCapture capture) {
                if (_isQRMode && capture.barcodes.isNotEmpty) {
                  final barcode = capture.barcodes.first;
                  if (barcode.rawValue != null) {
                    // No modo QR, detectar QR code automaticamente
                    widget.onQRCodeDetected(barcode.rawValue!);

                    // Também salvar a imagem se disponível
                    if (capture.image != null) {
                      _saveImageAndNotify(capture.image!);
                    }
                  }
                }
                // No modo de câmera normal, não fazer nada automaticamente
              },
            ),
          ),
          // Overlay com instruções
          if (_isQRMode)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black.withOpacity(0.5),
              width: double.infinity,
              child: const Text(
                'Posicione o QR Code no centro da tela para escanear automaticamente, ou toque no botão abaixo para tirar uma foto.',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          // Botão para tirar foto manualmente
          Container(
            color: Colors.black,
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Botão para voltar
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  color: Colors.white,
                  iconSize: 32,
                  onPressed: () => Navigator.pop(context),
                ),
                // Botão para tirar foto
                GestureDetector(
                  onTap: _capturePhoto,
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: const Center(
                      child: Icon(Icons.camera, color: Colors.white, size: 40),
                    ),
                  ),
                ),
                // Espaço para equilibrar o layout
                const SizedBox(width: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveImageAndNotify(Uint8List imageBytes) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final imagePath =
          '${tempDir.path}/qr_image_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Converter bytes em arquivo
      await File(imagePath).writeAsBytes(imageBytes);

      // Notificar sobre a foto tirada
      widget.onPhotoTaken(imagePath);
    } catch (e) {
      debugPrint('Erro ao salvar imagem: $e');
    }
  }
}
