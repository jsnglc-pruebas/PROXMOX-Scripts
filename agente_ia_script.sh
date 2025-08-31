#!/bin/bash

# =========================================================================
# Script de Provisión para Agente de IA en Proxmox
# Autor: [Tu Nombre Aquí]
# Versión: 2.0 (Interactiva)
# Descripción: Crea un contenedor LXC en Proxmox, instala dependencias
#              y configura un agente de IA experto en documentos.
# =========================================================================

# --- Interacción con el usuario ---
echo "--- Configuración del Agente IA ---"
echo "Este script te guiará para configurar el agente."

while true; do
    read -p "Ingresa la dirección IP de tu host de Proxmox (donde se ejecuta Ollama): " OLLAMA_HOST_IP
    if [[ -z "$OLLAMA_HOST_IP" ]]; then
        echo "La dirección IP no puede estar vacía. Por favor, inténtalo de nuevo."
    else
        break
    fi
done

read -p "Ingresa la URL del archivo PDF que el agente usará (deja en blanco para usar el ejemplo de Don Quijote): " LIBRO_PDF_URL

# Si el usuario no proporciona una URL, usamos la de Don Quijote por defecto.
if [[ -z "$LIBRO_PDF_URL" ]]; then
    LIBRO_PDF_URL="https://ia600903.us.archive.org/30/items/el-ingenioso-hidalgo-don-quijote-de-la-mancha-edicion-del-iv-centenario/El_ingenioso_hidalgo_don_Quijote_de_la_Mancha.pdf"
    echo "Usando el PDF de ejemplo: Don Quijote de la Mancha."
fi

# --- Configuración del contenedor LXC ---
# ¡IMPORTANTE! Asegúrate de que este ID no esté en uso.
CONTAINER_ID=103
CONTAINER_HOSTNAME="agente-ia-repo"
CONTAINER_MEMORY=4096  # 4GB de RAM
CONTAINER_DISK=10      # 10GB de disco

# --- Configuración de plantilla y red ---
TEMPLATE_URL="https://download.proxmox.com/images/rootfs/debian-12-standard_12.5-1_amd64.tar.zst"
TEMPLATE_NAME="debian-12-standard_12.5-1_amd64.tar.zst"
BRIDGE_NETWORK="vmbr0" # Nombre de tu puente de red en Proxmox

# --- Funciones ---
check_and_exit() {
    if [ $? -ne 0 ]; then
        echo "Error: Ocurrió un fallo en el último comando. Saliendo..."
        exit 1
    fi
}

# --- 1. Verificación de permisos de usuario ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script debe ser ejecutado como root o con sudo."
    exit 1
fi

# --- 2. Descargar plantilla si no existe ---
if [ ! -f "/var/lib/vz/template/cache/${TEMPLATE_NAME}" ]; then
    echo "Descargando plantilla de Debian 12..."
    wget -P /var/lib/vz/template/cache/ "${TEMPLATE_URL}"
    check_and_exit
else
    echo "Plantilla de Debian 12 ya existe." 
fi

# --- 3. Crear contenedor LXC ---
echo "Creando contenedor LXC con ID ${CONTAINER_ID}..."
pct create ${CONTAINER_ID} local:vztmpl/${TEMPLATE_NAME} \
    --hostname ${CONTAINER_HOSTNAME} \
    --ostype debian --cores 2 --memory ${CONTAINER_MEMORY} \
    --rootfs local-lvm:${CONTAINER_DISK} --unprivileged 1 \
    --net0 name=eth0,bridge=${BRIDGE_NETWORK},ip=dhcp
check_and_exit

# --- 4. Poner en marcha el contenedor ---
echo "Iniciando contenedor ${CONTAINER_ID}..."
pct start ${CONTAINER_ID}
sleep 15 # Esperamos a que el contenedor inicie completamente

# --- 5. Instalar dependencias dentro del contenedor ---
echo "Instalando dependencias en el contenedor..."
pct exec ${CONTAINER_ID} -- apt-get update
pct exec ${CONTAINER_ID} -- apt-get install -y python3 python3-pip python3-venv git wget build-essential
check_and_exit

# --- 6. Crear entorno virtual de Python e instalar librerías ---
echo "Creando entorno virtual de Python e instalando librerías..."
pct exec ${CONTAINER_ID} -- bash -c "python3 -m venv /opt/agente-venv && source /opt/agente-venv/bin/activate && pip install langchain-community pypdf chromadb sentence-transformers ollama"
check_and_exit

# --- 7. Descargar el PDF de ejemplo dentro del contenedor ---
echo "Descargando el PDF de ejemplo desde '${LIBRO_PDF_URL}'..."
pct exec ${CONTAINER_ID} -- bash -c "wget -O /opt/libro.pdf '${LIBRO_PDF_URL}'"
check_and_exit

# --- 8. Crear el script principal del agente ---
echo "Creando el script de Python para el agente..."
pct exec ${CONTAINER_ID} -- bash -c "cat > /opt/agente-ia.py" <<EOF
import os
import sys
from langchain.chains import create_retrieval_chain
from langchain_community.document_loaders import PyPDFLoader
from langchain_community.vectorstores import Chroma
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain_community.llms import Ollama
from langchain.prompts import PromptTemplate

# --- 1. Configuración del modelo y la base de datos de vectores ---
OLLAMA_HOST = "http://${OLLAMA_HOST_IP}:11434"
print(f"Conectando a Ollama en: {OLLAMA_HOST}")
llm = Ollama(model="llama3", base_url=OLLAMA_HOST)

# Usamos un modelo de embeddings pequeño y eficiente de Hugging Face
from langchain_community.embeddings import SentenceTransformerEmbeddings
embedding_function = SentenceTransformerEmbeddings(model_name="all-MiniLM-L6-v2")

# --- 2. Carga y pre-procesamiento del documento ---
print("Cargando y procesando el documento PDF...")
try:
    loader = PyPDFLoader("/opt/libro.pdf")
    docs = loader.load()
    text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
    split_docs = text_splitter.split_documents(docs)
    print(f"Documento dividido en {len(split_docs)} fragmentos.")
except Exception as e:
    print(f"Error al cargar el PDF: {e}")
    sys.exit(1)

# --- 3. Creación de la base de datos de conocimiento (Vector Store) ---
print("Creando la base de datos de vectores con ChromaDB...")
vectorstore = Chroma.from_documents(documents=split_docs, embedding=embedding_function)
retriever = vectorstore.as_retriever()

# --- 4. Definición de la cadena de RAG (Retrieval-Augmented Generation) ---
prompt_template = PromptTemplate.from_template("""
    Actúa como un asistente experto. Utiliza únicamente el siguiente contexto
    para responder a la pregunta. Si la respuesta no está en el contexto,
    responde que no lo sabes.

    Contexto: {context}

    Pregunta: {input}
""")
document_chain = create_stuff_documents_chain(llm, prompt_template)
retrieval_chain = create_retrieval_chain(retriever, document_chain)

# --- 5. Bucle de preguntas y respuestas ---
print("Agente listo. ¡Hazme una pregunta!")
print("Para salir, escribe 'salir'.")

while True:
    pregunta = input("Tu pregunta: ")
    if pregunta.lower() == "salir":
        break

    print("Buscando y generando respuesta...")
    try:
        response = retrieval_chain.invoke({"input": pregunta})
        respuesta_generada = response["answer"]
        print(f"Respuesta del agente: {respuesta_generada}")
        print("-" * 50)
    except Exception as e:
        print(f"Ocurrió un error al procesar la pregunta: {e}")
        print("-" * 50)

EOF

echo "¡Instalación y configuración completada!"
echo "Tu contenedor '${CONTAINER_HOSTNAME}' (${CONTAINER_ID}) está listo."
echo "Para comenzar a usar el agente, sigue estos pasos:"
echo "1. Conéctate al contenedor: pct enter ${CONTAINER_ID}"
echo "2. Activa el entorno virtual: source /opt/agente-venv/bin/activate"
echo "3. Ejecuta el agente: python3 /opt/agente-ia.py"
