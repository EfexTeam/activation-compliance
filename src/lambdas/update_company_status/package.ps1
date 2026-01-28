# Script PowerShell para empaquetar la función Lambda con sus dependencias

$ErrorActionPreference = "Stop"

$LAMBDA_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PACKAGE_DIR = Join-Path $LAMBDA_DIR "package"
$ZIP_FILE = Join-Path $LAMBDA_DIR "lambda-deployment.zip"

Write-Host "🧹 Limpiando directorio de empaquetado anterior..." -ForegroundColor Yellow
if (Test-Path $PACKAGE_DIR) {
    Remove-Item -Path $PACKAGE_DIR -Recurse -Force
}
if (Test-Path $ZIP_FILE) {
    Remove-Item -Path $ZIP_FILE -Force
}
New-Item -ItemType Directory -Path $PACKAGE_DIR -Force | Out-Null

Write-Host "📦 Instalando dependencias..." -ForegroundColor Yellow
pip install -r (Join-Path $LAMBDA_DIR "requirements.txt") -t $PACKAGE_DIR --upgrade

Write-Host "📋 Copiando código de la lambda..." -ForegroundColor Yellow
Copy-Item -Path (Join-Path $LAMBDA_DIR "lambda_handler.py") -Destination $PACKAGE_DIR

Write-Host "🗜️  Creando archivo ZIP..." -ForegroundColor Yellow
Compress-Archive -Path "$PACKAGE_DIR\*" -DestinationPath $ZIP_FILE -Force

$fileSize = (Get-Item $ZIP_FILE).Length / 1MB
Write-Host "✅ Empaquetado completado: $ZIP_FILE" -ForegroundColor Green
Write-Host "📊 Tamaño del paquete: $([math]::Round($fileSize, 2)) MB" -ForegroundColor Cyan
