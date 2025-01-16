import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart'; // Import correto do webview_flutter
import 'package:flutter_inappwebview/flutter_inappwebview.dart'; // Import correto do flutter_inappwebview
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
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
  String viewType = 'webview_flutter'; // Controla o tipo de WebView
  String option = 'A';
  bool showFrame = false;
  late WebViewController
      _webViewController; // WebViewController para controle da WebView
  late InAppWebViewController _inAppWebViewController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            debugPrint('Navegação iniciada: $url');
          },
          onPageFinished: (String url) {
            debugPrint('Navegação finalizada: $url');
          },
          onNavigationRequest: (NavigationRequest request) {
            if (request.url != _urlController.text) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  @override
  void dispose() {
    // Certifique-se de liberar o controlador do WebView
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      debugPrint('App minimizado');
      // Liberar recursos ou pausar processos aqui
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('App retomado');
      // Restaurar recursos ou retomar processos aqui
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
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
              content:
                  Text('Permissões de câmera e microfone são necessárias.')),
        );
        return false;
      }
    }
    return true;
  }

  void _openUrl() async {
    if (_formKey.currentState!.validate()) {
      String url = _urlController.text;
      switch (option) {
        case 'A':
          // Abrir na mesma página
          if (viewType == 'webview_flutter') {
            _webViewController.loadRequest(Uri.parse(url));
          } else {
            _inAppWebViewController.loadUrl(
                urlRequest: URLRequest(url: WebUri(url)));
          }
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
                body: viewType == 'webview_flutter'
                    ? WebViewWidget(
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
                      )
                    : InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(url)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                        ),
                        onWebViewCreated: (controller) {
                          _inAppWebViewController = controller;
                        },
                        shouldOverrideUrlLoading: (controller, request) async {
                          if (request.request.url.toString() != url) {
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
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
                child: viewType == 'webview_flutter'
                    ? WebViewWidget(
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
                      )
                    : InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(url)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                        ),
                        onWebViewCreated: (controller) {
                          _inAppWebViewController = controller;
                        },
                        shouldOverrideUrlLoading: (controller, request) async {
                          if (request.request.url.toString() != url) {
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
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
                  insetPadding: EdgeInsets.all(10),
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
                      child: viewType == 'webview_flutter'
                          ? WebViewWidget(
                              controller: WebViewController()
                                ..setJavaScriptMode(JavaScriptMode.unrestricted)
                                ..setNavigationDelegate(
                                  NavigationDelegate(
                                    onNavigationRequest:
                                        (NavigationRequest request) {
                                      if (request.url != url) {
                                        return NavigationDecision.prevent;
                                      }
                                      return NavigationDecision.navigate;
                                    },
                                  ),
                                )
                                ..loadRequest(Uri.parse(url)),
                            )
                          : InAppWebView(
                              initialUrlRequest: URLRequest(url: WebUri(url)),
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                supportZoom: true,
                              ),
                              onWebViewCreated: (controller) {
                                _inAppWebViewController = controller;
                              },
                              shouldOverrideUrlLoading:
                                  (controller, request) async {
                                if (request.request.url.toString() != url) {
                                  return NavigationActionPolicy.CANCEL;
                                }
                                return NavigationActionPolicy.ALLOW;
                              },
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
          if (viewType == 'webview_flutter') {
            // Carrega a URL no controlador existente da WebView
            _webViewController.loadRequest(Uri.parse(url));
          } else {
            // Carrega a URL no controlador existente do InAppWebView
            _inAppWebViewController.loadUrl(
              urlRequest: URLRequest(url: WebUri(url)),
            );
          }
          // Atualiza o estado para exibir o conteúdo em tela cheia
          setState(() {
            showFrame = true;
          });
          break;
        /* Abrir o WebView ocupando toda a página
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => Scaffold(
                appBar: AppBar(
                  title: const Text('WebView Fullscreen'),
                ),
                body: viewType == 'webview_flutter'
                    ? WebViewWidget(
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
                      )
                    : InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(url)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                        ),
                        onWebViewCreated: (controller) {
                          _inAppWebViewController = controller;
                        },
                        shouldOverrideUrlLoading: (controller, request) async {
                          if (request.request.url.toString() != url) {
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                      ),
              ),
            ),
          );
          break;
          */
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
              Column(
                children: [
                  Row(
                    children: [
                      Radio(
                        value: 'webview_flutter',
                        groupValue: viewType,
                        onChanged: (value) {
                          setState(() {
                            viewType = value!;
                          });
                        },
                      ),
                      const Text('webview_flutter'),
                    ],
                  ),
                  Row(
                    children: [
                      Radio(
                        value: 'flutter_inappwebview',
                        groupValue: viewType,
                        onChanged: (value) {
                          setState(() {
                            viewType = value!;
                          });
                        },
                      ),
                      const Text('flutter_inappwebview'),
                    ],
                  ),
                ],
              ),
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
              ElevatedButton(
                onPressed: () async {
                  if (_formKey.currentState!.validate()) {
                    bool permissionsGranted = await _checkPermissions();
                    if (!permissionsGranted) {
                      return;
                    }

                    _openUrl();
                  }
                },
                child: const Text('Executar'),
              ),
              if (showFrame && _urlController.text.isNotEmpty)
                Expanded(
                  child: viewType == 'webview_flutter'
                      ? WebViewWidget(
                          controller: _webViewController,
                        )
                      : InAppWebView(
                          initialUrlRequest: URLRequest(
                            url: WebUri(_urlController.text),
                          ),
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                          ),
                          onWebViewCreated: (controller) {
                            _inAppWebViewController = controller;
                          },
                          shouldOverrideUrlLoading:
                              (controller, request) async {
                            if (request.request.url.toString() !=
                                _urlController.text) {
                              return NavigationActionPolicy.CANCEL;
                            }
                            return NavigationActionPolicy.ALLOW;
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
