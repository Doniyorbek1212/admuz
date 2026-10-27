import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/strings.dart';

/// Full-screen camera that pops with the first QR code text it reads.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, this.hint});

  final String? hint;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (value == null || _done) return;
    _done = true;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(context.t('qr_scan'))),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(onDetect: _onDetect),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
              ),
            ),
            if (widget.hint != null)
              Positioned(
                left: 24,
                right: 24,
                bottom: 48,
                child: Text(widget.hint!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
          ],
        ),
      );
}
