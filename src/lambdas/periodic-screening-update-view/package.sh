#!/bin/bash
# Script para empaquetar la función Lambda con sus dependencias

set -e

LAMBDA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$LAMBDA_DIR/package"
ZIP_FILE="$LAMBDA_DIR/lambda-deployment.zip"

echo "🧹 Limpiando directorio de empaquetado anterior..."
rm -rf "$PACKAGE_DIR"
rm -f "$ZIP_FILE"
mkdir -p "$PACKAGE_DIR"

echo "📦 Instalando dependencias..."
pip install -r "$LAMBDA_DIR/requirements.txt" -t "$PACKAGE_DIR" --upgrade

echo "📋 Copiando código de la lambda..."
cp "$LAMBDA_DIR/lambda_handler.py" "$PACKAGE_DIR/"
cp "$LAMBDA_DIR/../db_utils.py" "$PACKAGE_DIR/"

echo "🗜️  Creando archivo ZIP..."
cd "$PACKAGE_DIR"
zip -r "$ZIP_FILE" . -q

echo "✅ Empaquetado completado: $ZIP_FILE"
echo "📊 Tamaño del paquete: $(du -h "$ZIP_FILE" | cut -f1)"
