import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:http/http.dart' as http;
import './camera-qr-scanner-widget.dart'; // Import the CameraWithQRScanner widget
import 'dart:io';
import 'dart:convert';
import 'dart:async';

// URL para enviar dados
const String apiUrl = 'http://192.168.31.194:3000/api/upload';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SentryFlutter.init(
    (options) {
      options.dsn =
          'https://5573f26d70d7e90910b448932b8d0626@o4508931864330240.ingest.us.sentry.io/4508931871866880';
      options.tracesSampleRate = 1.0; // Capture 100% dos traces
    },
    appRunner: () => runApp(const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter WebView Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const WebViewDemo(),
      navigatorObservers: [SentryNavigatorObserver()],
    );
  }
}

class WebViewDemo extends StatefulWidget {
  const WebViewDemo({super.key});

  @override
  WebViewDemoState createState() => WebViewDemoState();
}

class WebViewDemoState extends State<WebViewDemo> with WidgetsBindingObserver {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _urlController = TextEditingController();

  String option = 'A';
  bool showFrame = false;

  late final WebViewController _webViewController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Solicita permissões primeiro
    _requestPermissions().then((_) {
      // Inicializa o WebView após obter permissões
      _initializeWebView();

      // Carrega a página inicial após um pequeno atraso para garantir que tudo está pronto
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          // Carrega uma página HTML inicial simples
          _loadHtmlContent();
        }
      });
    });
  }

  void _initializeWebView() {
    // Cria e configura o WebView com persistência
    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

    // Configuração específica para Android
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);

      // Configurar para persistir dados entre sessões
      (controller.platform as AndroidWebViewController)
          .setOnPlatformPermissionRequest(
              (PlatformWebViewPermissionRequest request) => request.grant());
    }

    // Configuração específica para iOS (WebKit)
    if (controller.platform is WebKitWebViewController) {
      (controller.platform as WebKitWebViewController)
          .setAllowsBackForwardNavigationGestures(true);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            debugPrint('Navegação iniciada: $url');
          },
          onPageFinished: (String url) {
            debugPrint('Navegação finalizada: $url');
            // Verifica se o WebView está realmente pronto
            controller.runJavaScript(
                'document.body.style.backgroundColor = "white";');
          },
          onWebResourceError: (WebResourceError error) {
            _logError('WebView error: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            // Remove a restrição de navegação que pode estar causando problemas
            // Quando um QR code é escaneado, queremos permitir a navegação para essa URL
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('Mensagem do JavaScript: ${message.message}');
        },
      )
      // Configurar para persistência de cookies e localStorage
      ..setOnConsoleMessage((JavaScriptConsoleMessage message) {
        debugPrint('Console: ${message.message}');
      })
      // Define configurações para persistência
      ..enableZoom(true)
      ..setBackgroundColor(Colors.white) // Garante fundo branco
      ..setUserAgent('Mozilla/5.0 Flutter WebView')
      // Habilita armazenamento local (localStorage) e cookies
      ..setJavaScriptMode(JavaScriptMode.unrestricted);

    // Injetar um script para monitorar eventos relacionados a problemas de renderização
    controller.runJavaScript('''
      // Configurar detecção de problemas de renderização
      document.addEventListener('DOMContentLoaded', function() {
        console.log('DOM carregado completamente');
        document.body.style.backgroundColor = 'white';
      });
      
      // Monitorar erros de renderização
      window.addEventListener('error', function(e) {
        console.error('Erro de renderização:', e.message);
        window.Flutter.postMessage('Erro: ' + e.message);
      });
      
      // Configurar cookies via JavaScript
      document.cookie = "session_persistent=true; domain=.example.com; path=/; expires=${DateTime.now().add(const Duration(days: 365)).toUtc()}";
      localStorage.setItem('app_initialized', 'true');
      ''');

    _webViewController = controller;

    // Carregue uma página em branco para inicializar o WebView
    _webViewController.loadHtmlString('''
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { background-color: white; color: black; font-family: Arial, sans-serif; }
          </style>
        </head>
        <body>
          <div style="padding: 20px; text-align: center;">
            <h3>WebView inicializado</h3>
            <p>Insira uma URL ou escaneie um código QR para começar.</p>
          </div>
        </body>
      </html>
    ''');
  }

  void _logError(String message) {
    Sentry.captureMessage(message, level: SentryLevel.error);
    debugPrint('ERROR: $message');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      debugPrint('App minimizado');
      // Salvar estado da webview se necessário
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('App retomado');
      // Restaurar estado da webview se necessário
    } else if (state == AppLifecycleState.detached) {
      // App sendo fechado/destruído
      try {
        _webViewController.runJavaScript(
            'localStorage.setItem("app_closed_normally", "true");');
      } catch (e) {
        _logError('Erro ao salvar estado antes de fechar: $e');
      }
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.storage,
    ].request();
  }

  Future<bool> _checkPermissions() async {
    var cameraStatus = await Permission.camera.status;

    if (!cameraStatus.isGranted) {
      var results = [
        Permission.camera.request(),
      ];

      if ((await Future.wait(results)).every((status) => status.isGranted)) {
        return true;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Permissões de câmera são necessárias.')),
        );
        return false;
      }
    }
    return true;
  }

  Future<void> _scanQRCodeOrTakePicture() async {
    try {
      bool hasPermission = await _checkPermissions();
      if (!hasPermission) return;

      // Abre um modal customizado com câmera que permite escanear QR code ou tirar foto
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => Container(
          height: MediaQuery.of(context).size.height * 0.9,
          decoration: const BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: CameraWithQRScanner(
            onQRCodeDetected: (String code) async {
              // Fechar modal quando QR code for detectado
              Navigator.pop(context);

              // Processar o código QR
              setState(() {
                _urlController.text = code;
                showFrame = true;
              });

              // Registrar URL escaneada
              await _sendQrData(code);

              // Carregar URL na WebView - Garante que a WebView seja completamente recarregada
              await _loadUrlSafely(code);

              // Assegura que o estado está atualizado após a detecção do QR
              if (mounted) {
                setState(() {
                  showFrame = true;
                });
              }
            },
            onPhotoTaken: (String imagePath) async {
              // Fechar modal quando foto for tirada
              Navigator.pop(context);

              try {
                // Processar a foto
                await _uploadFile(imagePath, 'image');

                // Garantir que o WebView esteja visível
                if (mounted) {
                  setState(() {
                    showFrame = true;
                    // Carregar uma página em branco para garantir que o WebView esteja ativo
                    _loadHtmlContent();
                  });
                }

                // Pequeno atraso para permitir que o WebView seja inicializado
                await Future.delayed(const Duration(milliseconds: 500));

                // Informar a WebView sobre a imagem usando JavaScript
                final String base64Image =
                    base64Encode(await File(imagePath).readAsBytes());

                // Injeta JavaScript com pequeno atraso para garantir que a WebView esteja pronta
                await _webViewController.runJavaScript(
                    'window.dispatchEvent(new CustomEvent("imageSelected", {detail: "data:image/jpeg;base64,$base64Image"}));');

                // Para debug - Verifica se a WebView está respondendo
                await _webViewController.runJavaScript(
                    'console.log("WebView recebeu imagem com tamanho: " + "${base64Image.length}");');

                // Força uma atualização visual
                if (mounted) {
                  setState(() {});
                }
              } catch (e) {
                _logError('Erro ao processar imagem: $e');
                _showError('Erro ao processar imagem: $e');
              }
            },
          ),
        ),
      );
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao tirar foto ou escanear QR Code: $e');
    }
  }

  // Função auxiliar para carregar URLs com segurança
  Future<void> _loadUrlSafely(String url) async {
    try {
      await _webViewController.loadRequest(Uri.parse(url));

      // Verificar se a página carregou corretamente depois de um curto intervalo
      await Future.delayed(const Duration(seconds: 1));
      await _webViewController.runJavaScript('''
        if (document.body) {
          document.body.style.backgroundColor = "white";
          console.log("Página carregada e cor de fundo definida");
        } else {
          console.error("Corpo do documento não encontrado");
        }
      ''');
    } catch (e) {
      _logError('Erro ao carregar URL: $e');

      // Tenta recarregar a página em caso de erro
      try {
        await _webViewController.reload();
      } catch (reloadError) {
        _logError('Erro ao tentar recarregar: $reloadError');
      }
    }
  }

  // Carrega HTML base para garantir que o WebView está funcionando
  void _loadHtmlContent() {
    _webViewController.loadHtmlString('''
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { 
              background-color: white; 
              color: black; 
              font-family: Arial, sans-serif; 
              display: flex;
              justify-content: center;
              align-items: center;
              height: 100vh;
              margin: 0;
            }
            .container {
              text-align: center;
              padding: 20px;
            }
          </style>
          <script>
            // Escutar evento de imagem selecionada
            window.addEventListener('imageSelected', function(e) {
              console.log('Evento imageSelected recebido');
              const imageData = e.detail;
              displayImage(imageData);
            });
            
            function displayImage(imageData) {
              // Cria container para imagem
              const container = document.querySelector('.container');
              if (!container) return;
              
              // Limpa conteúdo atual
              container.innerHTML = '';
              
              // Cria elemento de imagem
              const img = document.createElement('img');
              img.src = imageData;
              img.style.maxWidth = '100%';
              img.style.borderRadius = '8px';
              img.style.boxShadow = '0 4px 8px rgba(0,0,0,0.1)';
              
              // Adiciona imagem ao container
              container.appendChild(img);
              
              console.log('Imagem exibida no DOM');
            }
          </script>
        </head>
        <body>
          <div class="container">
            <h3>Imagem sendo processada...</h3>
            <p>Aguarde um momento.</p>
          </div>
        </body>
      </html>
    ''');
  }

  // Função para enviar dados do QR Code para o servidor
  Future<void> _sendQrData(String qrData) async {
    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'type': 'qr_code', 'data': qrData}),
      );

      if (response.statusCode == 200) {
        debugPrint('QR Code enviado com sucesso');
      } else {
        _logError('Erro ao enviar QR Code: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _logError('Exceção ao enviar QR Code: $e');
    }
  }

  // Função para enviar arquivos para o servidor
  Future<void> _uploadFile(String filePath, String type) async {
    try {
      final uri = Uri.parse(apiUrl);
      final request = http.MultipartRequest('POST', uri);

      request.files.add(await http.MultipartFile.fromPath('file', filePath));
      request.fields['type'] = type;

      final response = await request.send();

      if (response.statusCode == 200) {
        debugPrint('Arquivo enviado com sucesso');
      } else {
        _logError('Erro ao enviar arquivo: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _logError('Exceção ao enviar arquivo: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openUrl() async {
    if (_formKey.currentState!.validate()) {
      String url = _urlController.text;
      switch (option) {
        case 'A':
          // Abrir na mesma página
          _webViewController.loadRequest(Uri.parse(url));
          setState(() {
            showFrame = true;
          });
          break;
        case 'B':
          // Abrir em uma nova página
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => Scaffold(
                appBar: AppBar(
                  title: const Text('WebView em Nova Página'),
                ),
                body: WebViewWidget(
                  controller: WebViewController()
                    ..setJavaScriptMode(JavaScriptMode.unrestricted)
                    ..setNavigationDelegate(
                      NavigationDelegate(
                        onNavigationRequest: (NavigationRequest request) {
                          if (request.url != url) {
                            return NavigationDecision.prevent;
                          }
                          return NavigationDecision.navigate;
                        },
                      ),
                    )
                    ..loadRequest(Uri.parse(url)),
                ),
              ),
            ),
          );
          break;
        case 'C':
          // Abrir em um modal
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              content: SizedBox(
                height: 400,
                child: WebViewWidget(
                  controller: WebViewController()
                    ..setJavaScriptMode(JavaScriptMode.unrestricted)
                    ..setNavigationDelegate(
                      NavigationDelegate(
                        onNavigationRequest: (NavigationRequest request) {
                          if (request.url != url) {
                            return NavigationDecision.prevent;
                          }
                          return NavigationDecision.navigate;
                        },
                      ),
                    )
                    ..loadRequest(Uri.parse(url)),
                ),
              ),
            ),
          );
          break;
        case 'D':
          // Abrir em um popup redimensionável
          showDialog(
            context: context,
            builder: (context) => StatefulBuilder(
              builder: (context, setState) {
                double dialogHeight = MediaQuery.of(context).size.height * 0.8;
                double dialogWidth = MediaQuery.of(context).size.width * 0.8;

                return Dialog(
                  insetPadding: const EdgeInsets.all(10),
                  backgroundColor: Colors.white,
                  child: Container(
                    height: dialogHeight,
                    width: dialogWidth,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: WebViewWidget(
                        controller: WebViewController()
                          ..setJavaScriptMode(JavaScriptMode.unrestricted)
                          ..setNavigationDelegate(
                            NavigationDelegate(
                              onNavigationRequest: (NavigationRequest request) {
                                if (request.url != url) {
                                  return NavigationDecision.prevent;
                                }
                                return NavigationDecision.navigate;
                              },
                            ),
                          )
                          ..loadRequest(Uri.parse(url)),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
          break;
        case 'E':
          // Abrir em um navegador externo
          if (await canLaunchUrl(Uri.parse(url))) {
            await launchUrl(Uri.parse(url));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Não foi possível abrir o navegador externo.')),
            );
          }
          break;
        case 'F':
          // Carrega a URL no controlador existente da WebView
          _webViewController.loadRequest(Uri.parse(url));

          // Atualiza o estado para exibir o conteúdo em tela cheia
          setState(() {
            showFrame = true;
          });
          break;
      }
    }
  }

  String? _validateUrl(String? value) {
    if (value == null || value.isEmpty) {
      return 'Por favor, insira uma URL';
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return 'Insira uma URL válida com http:// ou https://';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter WebView Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'URL',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                ),
                validator: _validateUrl,
              ),
              const SizedBox(height: 16.0),
              Column(
                children: ['A', 'B', 'C', 'D', 'E', 'F'].map((opt) {
                  return Row(
                    children: [
                      Radio(
                        value: opt,
                        groupValue: option,
                        onChanged: (value) {
                          setState(() {
                            option = value!;
                          });
                        },
                      ),
                      Text('Opção $opt'),
                    ],
                  );
                }).toList(),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      if (_formKey.currentState!.validate()) {
                        bool permissionsGranted = await _checkPermissions();
                        if (permissionsGranted) {
                          _openUrl();
                        }
                      }
                    },
                    child: const Text('Executar'),
                  ),
                  ElevatedButton(
                    onPressed: _scanQRCodeOrTakePicture,
                    child: const Icon(Icons.camera_alt),
                  ),
                ],
              ),
              if (showFrame && _urlController.text.isNotEmpty)
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        // WebView renderizado
                        WebViewWidget(
                          controller: _webViewController,
                        ),
                        // Indicador de carregamento simples
                        FutureBuilder<bool>(
                          future: Future.delayed(
                              const Duration(milliseconds: 500), () => true),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return Container(
                                color: Colors.white.withOpacity(0.7),
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class QRViewExample extends StatelessWidget {
  final Function(String) onCodeScanned;

  const QRViewExample({required this.onCodeScanned, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear QR Code'),
      ),
      body: MobileScanner(
        onDetect: (barcode) {
          if (barcode.barcodes.isNotEmpty) {
            final String code = barcode.barcodes.first.rawValue!;
            onCodeScanned(code);
            Navigator.pop(context);
          }
        },
      ),
    );
  }
}
