const express = require("express");
const multer = require("multer");
const cors = require("cors");
const fs = require("fs");
const path = require("path");
const app = express();
const port = 3000;

// Configurar CORS para permitir requisições do app Flutter
app.use(cors());

// Configurar para processar JSON
app.use(express.json());

// Configurar pasta para salvar arquivos
const uploadDir = path.join(__dirname, "uploads");
if (!fs.existsSync(uploadDir)) {
  fs.mkdirSync(uploadDir);
}

// Configurar o multer para armazenar arquivos
const storage = multer.diskStorage({
  destination: function (req, file, cb) {
    cb(null, uploadDir);
  },
  filename: function (req, file, cb) {
    const uniqueSuffix = Date.now() + "-" + Math.round(Math.random() * 1e9);
    cb(null, uniqueSuffix + path.extname(file.originalname));
  },
});

const upload = multer({ storage: storage });

// Rota para verificar se o servidor está online
app.get("/", (req, res) => {
  res.send("API Mock para testes está online!");
});

// Endpoint unificado para receber uploads de arquivos ou dados QR
app.post("/api/upload", upload.single("file"), (req, res) => {
  console.log("Corpo da requisição:", req.body);

  // Verificar se é um upload de QR code (sem arquivo)
  if (req.body.type === "qr_code" && req.body.data && !req.file) {
    console.log("Dados QR recebidos:", req.body);

    // Salvar em um arquivo de log
    const logPath = path.join(uploadDir, "qr_codes.json");
    let logs = [];

    if (fs.existsSync(logPath)) {
      try {
        logs = JSON.parse(fs.readFileSync(logPath));
      } catch (e) {
        console.error("Erro ao ler arquivo de logs:", e);
      }
    }

    logs.push({
      timestamp: new Date().toISOString(),
      data: req.body.data,
    });

    fs.writeFileSync(logPath, JSON.stringify(logs, null, 2));

    return res
      .status(200)
      .json({ success: true, message: "QR Code registrado com sucesso" });
  }

  // Verificar se é um upload de arquivo
  if (req.file) {
    console.log("Arquivo recebido:", req.file);
    console.log("Tipo de upload:", req.body.type);

    // Criar um registro do upload
    const logEntry = {
      timestamp: new Date().toISOString(),
      filename: req.file.filename,
      originalName: req.file.originalname,
      size: req.file.size,
      type: req.body.type || "unknown",
      mimetype: req.file.mimetype,
      path: req.file.path,
    };

    // Salvar um registro de upload
    const logPath = path.join(uploadDir, "uploads.json");
    let logs = [];

    if (fs.existsSync(logPath)) {
      try {
        logs = JSON.parse(fs.readFileSync(logPath));
      } catch (e) {
        console.error("Erro ao ler arquivo de logs:", e);
      }
    }

    logs.push(logEntry);
    fs.writeFileSync(logPath, JSON.stringify(logs, null, 2));

    return res.status(200).json({
      success: true,
      message: "Arquivo recebido com sucesso",
      file: {
        filename: req.file.filename,
        size: req.file.size,
        path: `/uploads/${req.file.filename}`,
      },
    });
  }

  // Se não for nenhum dos casos acima
  return res
    .status(400)
    .json({
      success: false,
      message: "Requisição inválida. Nenhum dado reconhecido.",
    });
});

// Rota para interface web básica para ver uploads
app.get("/uploads", (req, res) => {
  const uploadLogs = fs.existsSync(path.join(uploadDir, "uploads.json"))
    ? JSON.parse(fs.readFileSync(path.join(uploadDir, "uploads.json")))
    : [];

  const qrLogs = fs.existsSync(path.join(uploadDir, "qr_codes.json"))
    ? JSON.parse(fs.readFileSync(path.join(uploadDir, "qr_codes.json")))
    : [];

  let html = `
    <!DOCTYPE html>
    <html>
    <head>
      <title>Mock API Dashboard</title>
      <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1, h2 { color: #333; }
        .card { border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 5px; }
        .timestamp { color: #888; font-size: 0.85em; }
        img { max-width: 300px; max-height: 300px; margin-top: 10px; }
      </style>
    </head>
    <body>
      <h1>Mock API Dashboard</h1>
      
      <h2>Uploads Recebidos (${uploadLogs.length})</h2>
  `;

  if (uploadLogs.length === 0) {
    html += "<p>Nenhum upload recebido ainda.</p>";
  } else {
    uploadLogs.reverse().forEach((log) => {
      html += `
        <div class="card">
          <div><strong>Arquivo:</strong> ${log.originalName}</div>
          <div><strong>Tipo:</strong> ${log.type}</div>
          <div><strong>Tamanho:</strong> ${Math.round(log.size / 1024)} KB</div>
          <div class="timestamp">${new Date(
            log.timestamp
          ).toLocaleString()}</div>
          ${
            log.mimetype.startsWith("image/")
              ? `<img src="/uploads/${log.filename}" />`
              : ""
          }
        </div>
      `;
    });
  }

  html += `
      <h2>QR Codes Recebidos (${qrLogs.length})</h2>
  `;

  if (qrLogs.length === 0) {
    html += "<p>Nenhum QR code recebido ainda.</p>";
  } else {
    qrLogs.reverse().forEach((log) => {
      html += `
        <div class="card">
          <div><strong>Dados:</strong> ${log.data}</div>
          <div class="timestamp">${new Date(
            log.timestamp
          ).toLocaleString()}</div>
        </div>
      `;
    });
  }

  html += `
    </body>
    </html>
  `;

  res.send(html);
});

// Rota para acessar os arquivos
app.use("/uploads", express.static(uploadDir));

// Iniciar o servidor
app.listen(port, () => {
  console.log(`Servidor de mock API rodando em http://localhost:${port}`);
  console.log(`Dashboard de uploads em http://localhost:${port}/uploads`);
});
