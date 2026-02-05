#!/bin/bash
#
# Push-to-Talk - Instalacao
# Ditado por voz em portugues brasileiro usando Vosk
#
# Uso: chmod +x install.sh && ./install.sh
#

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Diretorios
INSTALL_DIR="$HOME/nerd-dictation"
VENV_DIR="$INSTALL_DIR/nerd-dictation-env"
MODELS_DIR="$INSTALL_DIR/models"
BIN_DIR="$HOME/bin"
CONFIG_DIR="$HOME/.config/dictation"
CONFIG_FILE="$CONFIG_DIR/config.json"

# URLs
MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-pt-fb-v0.1.1-20220516_2113.zip"
MODEL_NAME="vosk-model-pt-fb-v0.1.1-20220516_2113"

echo -e "${BLUE}"
echo "================================================"
echo "          Push-to-Talk - Instalacao"
echo "     Ditado por voz em Portugues (Brasil)"
echo "================================================"
echo -e "${NC}"

# Funcoes de output
print_status() {
    echo -e "${GREEN}[OK] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[AVISO] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERRO] $1${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# ============================================================
# ETAPA 1: Verificar e instalar dependencias do sistema
# ============================================================
echo ""
echo -e "${BLUE}[1/5] Verificando dependencias do sistema...${NC}"
echo "------------------------------------------------"

DEPS_TO_INSTALL=""

declare -A PACKAGES=(
    ["python3"]="python3"
    ["python3-venv"]="python3-venv"
    ["python3-pip"]="python3-pip"
    ["xclip"]="xclip"
    ["xdotool"]="xdotool"
    ["parecord"]="pulseaudio-utils"
    ["unzip"]="unzip"
    ["wget"]="wget"
)

for cmd in "${!PACKAGES[@]}"; do
    pkg="${PACKAGES[$cmd]}"
    if ! command -v "$cmd" &> /dev/null && ! dpkg -l | grep -q "^ii  $pkg "; then
        DEPS_TO_INSTALL="$DEPS_TO_INSTALL $pkg"
    else
        print_status "$cmd disponivel"
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    print_info "Instalando pacotes:$DEPS_TO_INSTALL"
    sudo apt update
    sudo apt install -y $DEPS_TO_INSTALL
    print_status "Pacotes instalados"
else
    print_status "Todas as dependencias ja estao instaladas"
fi

# ============================================================
# ETAPA 2: Criar estrutura de diretorios
# ============================================================
echo ""
echo -e "${BLUE}[2/5] Criando estrutura de diretorios...${NC}"
echo "------------------------------------------------"

mkdir -p "$INSTALL_DIR"
mkdir -p "$MODELS_DIR"
mkdir -p "$BIN_DIR"
mkdir -p "$CONFIG_DIR"

print_status "Diretorios criados"

# ============================================================
# ETAPA 3: Criar ambiente virtual Python
# ============================================================
echo ""
echo -e "${BLUE}[3/5] Configurando ambiente Python...${NC}"
echo "------------------------------------------------"

if [ ! -d "$VENV_DIR" ]; then
    print_info "Criando ambiente virtual..."
    python3 -m venv "$VENV_DIR"
    print_status "Ambiente virtual criado"
else
    print_status "Ambiente virtual ja existe"
fi

source "$VENV_DIR/bin/activate"

print_info "Instalando dependencias Python..."
pip install --upgrade pip --quiet
pip install vosk pynput --quiet

print_status "Dependencias Python instaladas (vosk, pynput)"

# ============================================================
# ETAPA 4: Baixar modelo Vosk para Portugues
# ============================================================
echo ""
echo -e "${BLUE}[4/5] Configurando modelo de voz...${NC}"
echo "------------------------------------------------"

if [ -d "$MODELS_DIR/$MODEL_NAME" ]; then
    print_status "Modelo Vosk ja esta instalado"
else
    print_info "Baixando modelo Vosk para Portugues (~1.6GB)..."
    print_info "Isso pode demorar alguns minutos..."
    
    cd "$MODELS_DIR"
    wget -q --show-progress "$MODEL_URL" -O model.zip
    
    print_info "Extraindo modelo..."
    unzip -q model.zip
    rm model.zip
    
    print_status "Modelo Vosk instalado"
fi

# ============================================================
# ETAPA 5: Instalar scripts
# ============================================================
echo ""
echo -e "${BLUE}[5/5] Instalando scripts...${NC}"
echo "------------------------------------------------"

# ==================== SCRIPT PRINCIPAL ====================
cat > "$INSTALL_DIR/push-to-talk.py" << 'ENDOFPYTHON'
#!/usr/bin/env python3
"""
Push-to-Talk - Ditado por voz em portugues brasileiro.
Tecla de ativacao configuravel via ~/.config/dictation/config.json
"""

import subprocess
import os
import tempfile
import threading
import time
import wave
import json
from pynput import keyboard

try:
    from vosk import Model, KaldiRecognizer
    VOSK_AVAILABLE = True
except ImportError:
    VOSK_AVAILABLE = False
    print("[AVISO] vosk nao instalado.")

NERD_DIR = os.path.expanduser("~/nerd-dictation")
MODEL_DIR = f"{NERD_DIR}/models/vosk-model-pt-fb-v0.1.1-20220516_2113"
CONFIG_FILE = os.path.expanduser("~/.config/dictation/config.json")
SAMPLE_RATE = 16000

is_recording = False
recording_process = None
audio_file_path = None
lock = threading.Lock()
model = None
activation_keys = []  # Lista de strings de teclas
activation_key_name = "Nao configurada"

# Mapeamento de codigos virtuais especiais
VK_MAP = {
    65027: 'alt_gr',
    65107: 'scroll_lock', 
    65299: 'pause',
    65379: 'insert',
    65535: 'delete',
}


def load_config():
    global activation_keys, activation_key_name
    
    if not os.path.exists(CONFIG_FILE):
        print("[ERRO] Nenhuma tecla configurada!")
        print("       Execute: dictation-config")
        return False
    
    try:
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
        
        activation_keys = config.get("activation_keys", [])
        activation_key_name = config.get("activation_key_name", "Tecla configurada")
        
        if activation_keys:
            print(f"[OK] Tecla configurada: {activation_key_name}")
            return True
        else:
            print("[ERRO] Nenhuma tecla valida na configuracao!")
            return False
            
    except Exception as e:
        print(f"[ERRO] Falha ao ler configuracao: {e}")
        return False


def key_matches(key, key_str):
    """Verifica se uma tecla corresponde a string de configuracao."""
    
    # Formato: vk:CODIGO (codigo virtual)
    if key_str.startswith("vk:"):
        try:
            target_vk = int(key_str[3:])
            if hasattr(key, 'vk') and key.vk == target_vk:
                return True
        except:
            pass
        return False
    
    # Formato: Key.nome (tecla especial)
    if key_str.startswith("Key."):
        target_name = key_str[4:]
        
        # Verifica pelo nome direto
        if hasattr(key, 'name') and key.name == target_name:
            return True
        
        # Verifica pelo codigo virtual mapeado
        if hasattr(key, 'vk') and key.vk in VK_MAP:
            if VK_MAP[key.vk] == target_name:
                return True
        
        return False
    
    # Formato: 'char' (caractere)
    if key_str.startswith("'") and key_str.endswith("'"):
        target_char = key_str[1:-1]
        if hasattr(key, 'char') and key.char == target_char:
            return True
        return False
    
    return False


def load_model():
    global model
    if VOSK_AVAILABLE and model is None:
        print("[INFO] Carregando modelo vosk...")
        try:
            model = Model(MODEL_DIR)
            print("[OK] Modelo carregado!")
        except Exception as e:
            print(f"[ERRO] Erro ao carregar modelo: {e}")


def start_recording():
    global is_recording, recording_process, audio_file_path
    
    with lock:
        if is_recording:
            return
        
        fd, audio_file_path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        
        print(f"[REC] Gravando... (segure {activation_key_name})")
        
        recorders = [
            ["parecord", "--rate", str(SAMPLE_RATE), "--channels", "1", 
             "--format", "s16le", "--file-format=wav", audio_file_path],
            ["arecord", "-f", "S16_LE", "-r", str(SAMPLE_RATE), 
             "-c", "1", "-t", "wav", audio_file_path]
        ]
        
        for cmd in recorders:
            try:
                recording_process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                is_recording = True
                return
            except FileNotFoundError:
                continue
        
        print("[ERRO] Nenhum gravador disponivel!")


def stop_recording_and_transcribe():
    global is_recording, recording_process, audio_file_path
    
    with lock:
        if not is_recording:
            return
        
        print("[INFO] Processando audio...")
        
        if recording_process:
            recording_process.terminate()
            try:
                recording_process.wait(timeout=2)
            except:
                recording_process.kill()
            recording_process = None
        
        is_recording = False
        time.sleep(0.1)
        
        if audio_file_path and os.path.exists(audio_file_path):
            path = audio_file_path
            audio_file_path = None
            thread = threading.Thread(target=transcribe_and_paste, args=(path,))
            thread.daemon = True
            thread.start()


def transcribe_with_vosk(audio_path):
    global model
    if model is None:
        return None
    try:
        wf = wave.open(audio_path, "rb")
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            return None
        rec = KaldiRecognizer(model, wf.getframerate())
        rec.SetWords(True)
        results = []
        while True:
            data = wf.readframes(4000)
            if len(data) == 0:
                break
            if rec.AcceptWaveform(data):
                result = json.loads(rec.Result())
                if result.get("text"):
                    results.append(result["text"])
        final = json.loads(rec.FinalResult())
        if final.get("text"):
            results.append(final["text"])
        wf.close()
        return " ".join(results).strip()
    except Exception as e:
        print(f"[ERRO] Transcricao: {e}")
        return None


def transcribe_and_paste(audio_path):
    text = transcribe_with_vosk(audio_path) if VOSK_AVAILABLE and model else None
    
    try:
        if audio_path and os.path.exists(audio_path):
            os.unlink(audio_path)
    except:
        pass
    
    if text:
        try:
            process = subprocess.Popen(["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE)
            process.communicate(input=text.encode('utf-8'))
            time.sleep(0.05)
            subprocess.run(["xdotool", "key", "ctrl+v"], check=True)
            print(f"[OK] Colado: \"{text}\"")
        except Exception as e:
            print(f"[ERRO] Ao colar: {e}")
            print(f"       Texto: {text}")
    else:
        print("[AVISO] Nenhum texto detectado")


# Estado das teclas pressionadas
pressed_keys = set()
pressed_keys_str = set()  # Strings das teclas ativas


def on_press(key):
    global pressed_keys, pressed_keys_str
    
    pressed_keys.add(key)
    
    # Verifica quais teclas de ativacao estao pressionadas
    for key_str in activation_keys:
        if key_matches(key, key_str):
            pressed_keys_str.add(key_str)
    
    # Se todas as teclas de ativacao estao pressionadas, inicia gravacao
    if pressed_keys_str and set(activation_keys).issubset(pressed_keys_str):
        start_recording()


def on_release(key):
    global pressed_keys, pressed_keys_str, recording_process
    
    # Verifica se alguma tecla de ativacao foi solta
    for key_str in activation_keys:
        if key_matches(key, key_str):
            pressed_keys_str.discard(key_str)
            if is_recording:
                stop_recording_and_transcribe()
                break
    
    pressed_keys.discard(key)
    
    if key == keyboard.Key.esc:
        print("\n[INFO] Encerrando...")
        if recording_process:
            recording_process.terminate()
        return False


def check_dependencies():
    errors = []
    for recorder in ["parecord", "arecord"]:
        if subprocess.run(["which", recorder], capture_output=True).returncode == 0:
            print(f"[OK] Gravador: {recorder}")
            break
    else:
        errors.append("Gravador de audio")
    
    for tool in ["xclip", "xdotool"]:
        if subprocess.run(["which", tool], capture_output=True).returncode == 0:
            print(f"[OK] {tool}")
        else:
            errors.append(tool)
    
    if os.path.exists(MODEL_DIR):
        print("[OK] Modelo vosk")
    else:
        errors.append("Modelo vosk")
    
    if VOSK_AVAILABLE:
        print("[OK] Biblioteca vosk")
    else:
        errors.append("Biblioteca vosk")
    
    return len(errors) == 0


def main():
    print("=" * 55)
    print("    Push-to-Talk - Ditado por Voz")
    print("=" * 55)
    print()
    
    if not load_config():
        return
    
    print()
    print("[INFO] Verificando dependencias...")
    check_dependencies()
    
    load_model()
    
    print("\n" + "=" * 55)
    print("INSTRUCOES:")
    print(f"   Tecla: {activation_key_name}")
    print("   Segure para gravar, solte para transcrever")
    print("   ESC para sair")
    print("=" * 55)
    print(f"\n[INFO] Aguardando {activation_key_name}...\n")
    
    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


if __name__ == "__main__":
    main()
ENDOFPYTHON

chmod +x "$INSTALL_DIR/push-to-talk.py"
print_status "Script principal instalado"

# ==================== SCRIPT DE CONFIGURACAO ====================
cat > "$INSTALL_DIR/configure-key.py" << 'ENDOFCONFIG'
#!/usr/bin/env python3
"""
Configurador de Tecla - Captura combinacao de teclas
"""

import os
import json
import sys
from pynput import keyboard

CONFIG_DIR = os.path.expanduser("~/.config/dictation")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")

pressed_keys = set()
captured_keys = []  # Lista para manter ordem
captured_keys_set = set()  # Set para evitar duplicatas

# Mapeamento de codigos especiais (varia por sistema)
SPECIAL_KEYCODES = {
    65027: ('AltGr', 'Key.alt_gr'),
    65107: ('Scroll Lock', 'Key.scroll_lock'),
    65299: ('Pause', 'Key.pause'),
    65379: ('Insert', 'Key.insert'),
    65535: ('Delete', 'Key.delete'),
}

# Ordem de prioridade para modificadores (aparecem primeiro)
MODIFIER_ORDER = {
    'ctrl': 1, 'ctrl_l': 1, 'ctrl_r': 1,
    'alt': 2, 'alt_l': 2, 'alt_r': 2, 'alt_gr': 2,
    'shift': 3, 'shift_l': 3, 'shift_r': 3,
    'cmd': 4, 'cmd_l': 4, 'cmd_r': 4,
    'super': 4, 'super_l': 4, 'super_r': 4,
}


def get_key_info(key):
    """Retorna (display_name, storage_string, sort_order) para uma tecla."""
    
    # Verifica se e um KeyCode com vk (codigo virtual)
    if hasattr(key, 'vk') and key.vk:
        vk = key.vk
        if vk in SPECIAL_KEYCODES:
            display, storage = SPECIAL_KEYCODES[vk]
            return (display, storage, 10)
        # Codigo desconhecido
        return (f"Tecla({vk})", f"vk:{vk}", 10)
    
    # Tecla especial com nome
    if hasattr(key, 'name') and key.name:
        name = key.name
        friendly = {
            'alt_gr': 'AltGr',
            'alt_l': 'Alt',
            'alt_r': 'Alt',
            'alt': 'Alt',
            'ctrl_l': 'Ctrl',
            'ctrl_r': 'Ctrl',
            'ctrl': 'Ctrl',
            'shift_l': 'Shift',
            'shift_r': 'Shift',
            'shift': 'Shift',
            'cmd': 'Super',
            'cmd_l': 'Super',
            'cmd_r': 'Super',
            'space': 'Espaco',
            'enter': 'Enter',
            'tab': 'Tab',
            'caps_lock': 'CapsLock',
            'scroll_lock': 'ScrollLock',
            'num_lock': 'NumLock',
            'pause': 'Pause',
            'insert': 'Insert',
            'delete': 'Delete',
            'home': 'Home',
            'end': 'End',
            'page_up': 'PageUp',
            'page_down': 'PageDown',
            'backspace': 'Backspace',
        }
        display = friendly.get(name, name.upper() if len(name) <= 3 else name.capitalize())
        storage = f"Key.{name}"
        order = MODIFIER_ORDER.get(name, 10)
        return (display, storage, order)
    
    # Tecla de caractere
    if hasattr(key, 'char') and key.char:
        char = key.char.upper()
        return (char, f"'{key.char}'", 20)
    
    # Fallback
    return (str(key), str(key), 30)


def get_display_sorted(keys_list):
    """Retorna string de display com modificadores primeiro."""
    # Obtem info de cada tecla
    info_list = [get_key_info(k) for k in keys_list]
    # Ordena por prioridade
    info_list.sort(key=lambda x: (x[2], x[0]))
    # Junta os nomes
    return " + ".join([info[0] for info in info_list])


def on_press(key):
    global pressed_keys, captured_keys, captured_keys_set
    
    if key == keyboard.Key.esc:
        return False
    
    pressed_keys.add(key)
    
    # Adiciona se ainda nao foi capturada (evita duplicatas)
    key_id = str(key)
    if key_id not in captured_keys_set:
        captured_keys_set.add(key_id)
        captured_keys.append(key)
    
    # Atualiza display
    display = get_display_sorted(captured_keys)
    print(f"\r[CAPTURANDO] {display}                    ", end="", flush=True)


def on_release(key):
    global pressed_keys
    
    if key == keyboard.Key.esc:
        return False
    
    pressed_keys.discard(key)
    
    # Se todas as teclas foram soltas, termina a captura
    if len(pressed_keys) == 0 and len(captured_keys) > 0:
        return False


def capture_keys():
    """Captura combinacao de teclas."""
    global pressed_keys, captured_keys, captured_keys_set
    
    pressed_keys = set()
    captured_keys = []
    captured_keys_set = set()
    
    print("\n" + "=" * 30)
    print("    CONFIGURACAO DE TECLA")
    print("=" * 30)
    print("\nPressione a(s) tecla(s) que deseja usar.")
    print("Pode ser uma tecla unica ou combinacao (ex: Ctrl+Shift+D)")
    print("Solte todas as teclas para confirmar.")
    print("Pressione ESC para cancelar.")
    print()
    print("[CAPTURANDO] Aguardando tecla...                    ", end="", flush=True)
    
    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
    
    print()
    
    if not captured_keys:
        return None, None
    
    # Converte para formato de armazenamento
    keys_str = []
    for key in captured_keys:
        _, storage, _ = get_key_info(key)
        if storage:
            keys_str.append(storage)
    
    display_name = get_display_sorted(captured_keys)
    
    return keys_str, display_name


def save_config(keys_str, display_name):
    """Salva configuracao."""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    
    config = {
        "activation_keys": keys_str,
        "activation_key_name": display_name
    }
    
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)


def main():
    while True:
        keys_str, display_name = capture_keys()
        
        if not keys_str:
            print("\n[CANCELADO] Nenhuma tecla capturada.")
            sys.exit(1)
        
        print(f"\n[RESULTADO] Tecla(s) capturada(s): {display_name}")
        print()
        
        while True:
            choice = input("Confirmar esta configuracao? [S/n/r] (r=refazer): ").strip().lower()
            
            if choice in ['', 's', 'sim', 'y', 'yes']:
                save_config(keys_str, display_name)
                print(f"\n[OK] Configuracao salva!")
                print(f"     Tecla de ativacao: {display_name}")
                return True
            elif choice in ['r', 'refazer']:
                break  # Volta para captura
            elif choice in ['n', 'nao', 'no']:
                print("\n[CANCELADO]")
                sys.exit(1)
            else:
                print("Opcao invalida. Use: S (sim), N (nao), R (refazer)")


if __name__ == "__main__":
    main()
ENDOFCONFIG

chmod +x "$INSTALL_DIR/configure-key.py"
print_status "Configurador de tecla instalado"

# ==================== WRAPPER DICTATION ====================
cat > "$BIN_DIR/dictation" << ENDOFWRAPPER
#!/bin/bash
source "$VENV_DIR/bin/activate"
exec python3 "$INSTALL_DIR/push-to-talk.py" "\$@"
ENDOFWRAPPER

chmod +x "$BIN_DIR/dictation"
print_status "Comando 'dictation' criado"

# ==================== WRAPPER DICTATION-CONFIG ====================
cat > "$BIN_DIR/dictation-config" << ENDOFWRAPPER2
#!/bin/bash
source "$VENV_DIR/bin/activate"
exec python3 "$INSTALL_DIR/configure-key.py" "\$@"
ENDOFWRAPPER2

chmod +x "$BIN_DIR/dictation-config"
print_status "Comando 'dictation-config' criado"

# ============================================================
# CONFIGURACAO DE TECLA
# ============================================================
echo ""
echo ""
echo "Agora vamos configurar a tecla de ativacao."

# Executa o configurador de tecla
python3 "$INSTALL_DIR/configure-key.py"
CONFIG_RESULT=$?

if [ $CONFIG_RESULT -ne 0 ]; then
    echo ""
    print_warning "Configuracao de tecla cancelada."
    echo "         Para configurar depois, execute: dictation-config"
fi

# ============================================================
# INSTRUCOES FINAIS
# ============================================================
echo ""
echo -e "${BLUE}========================================================"
echo "                    COMO USAR"
echo -e "========================================================${NC}"
echo ""
echo "1. Abra um terminal e execute:"
echo ""
echo -e "   ${GREEN}\$ dictation${NC}"
echo ""
echo "2. Posicione o cursor onde deseja inserir texto"
echo ""
echo "3. Segure a tecla configurada, fale, e solte"
echo ""
echo "4. O texto sera colado automaticamente"
echo ""
echo -e "${BLUE}--------------------------------------------------------${NC}"
echo ""
echo "Comandos disponiveis:"
echo "   dictation        - Inicia o ditado por voz"
echo "   dictation-config - Reconfigura a tecla de ativacao"
echo ""

# Verifica PATH
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo -e "${YELLOW}IMPORTANTE:${NC}"
    echo "   Adicione ~/bin ao seu PATH executando:"
    echo ""
    echo "   echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.bashrc"
    echo "   source ~/.bashrc"
    echo ""
fi

echo -e "${GREEN}Instalacao finalizada!${NC}"
echo ""