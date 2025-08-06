#!/bin/bash

# Скрипт для проверки валидности видео файлов с помощью ffmpeg
# Поддерживает рекурсивный поиск и обработку имен с пробелами, спецсимволами и эмодзи

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для проверки наличия ffmpeg
check_ffmpeg() {
    if ! command -v ffmpeg &> /dev/null; then
        echo -e "${RED}Ошибка: ffmpeg не найден в системе${NC}" >&2
        exit 1
    fi
}

# Функция вывода справки
show_help() {
    echo "Использование: $0 [опции] [директория]"
    echo ""
    echo "Опции:"
    echo "  -h, --help     Показать эту справку"
    echo "  -e, --ext      Расширения файлов для проверки (по умолчанию: mp4,avi,mkv,mov,wmv,flv,webm,m4v,3gp)"
    echo "  -o, --output   Файл для сохранения результатов"
    echo "  -f, --full     Полная проверка файла (по умолчанию только заголовок)"
    echo "  -m, --move     Перемещать поврежденные файлы в папку 'broken'"
    echo ""
    echo "Примеры:"
    echo "  $0 /path/to/videos"
    echo "  $0 -e \"mp4,avi\" -o results.log /path/to/videos"
    echo "  $0 --full /path/to/videos  # полная проверка (медленнее)"
    echo "  $0 --move /path/to/videos  # перемещать поврежденные файлы"
}

# Переменные по умолчанию
EXTENSIONS="mp4,avi,mkv,mov,wmv,flv,webm,m4v,3gp"
OUTPUT_FILE=""
SEARCH_DIR="."
FULL_CHECK=false
MOVE_BROKEN=false

# Обработка аргументов командной строки
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -e|--ext)
            EXTENSIONS="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -f|--full)
            FULL_CHECK=true
            shift
            ;;
        -m|--move)
            MOVE_BROKEN=true
            shift
            ;;
        -*)
            echo -e "${RED}Неизвестная опция: $1${NC}" >&2
            show_help
            exit 1
            ;;
        *)
            SEARCH_DIR="$1"
            shift
            ;;
    esac
done

# Проверяем наличие ffmpeg
check_ffmpeg

# Проверяем существование директории
if [[ ! -d "$SEARCH_DIR" ]]; then
    echo -e "${RED}Ошибка: Директория '$SEARCH_DIR' не существует${NC}" >&2
    exit 1
fi

# Создаем папку broken если включено перемещение поврежденных файлов
BROKEN_DIR=""
if [[ "$MOVE_BROKEN" == true ]]; then
    BROKEN_DIR="$SEARCH_DIR/broken"
    if [[ ! -d "$BROKEN_DIR" ]]; then
        mkdir -p "$BROKEN_DIR"
        echo "Создана папка для поврежденных файлов: $BROKEN_DIR"
    fi
fi

# Создаем массив расширений
IFS=',' read -ra EXT_ARRAY <<< "$EXTENSIONS"

# Строим условие для find
FIND_CONDITION=""
for i in "${!EXT_ARRAY[@]}"; do
    ext="${EXT_ARRAY[$i]}"
    if [[ $i -eq 0 ]]; then
        FIND_CONDITION="-iname *.${ext}"
    else
        FIND_CONDITION="$FIND_CONDITION -o -iname *.${ext}"
    fi
done

# Инициализация файла результатов
if [[ -n "$OUTPUT_FILE" ]]; then
    > "$OUTPUT_FILE"
fi

# Счетчики
total_files=0
valid_files=0
invalid_files=0
warning_files=0

# Устанавливаем локаль для корректной работы с UTF-8 (эмодзи)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Создаем временный файл для списка файлов
temp_file_list=$(mktemp)

# Находим все видео файлы и сохраняем в временный файл
echo "Поиск видео файлов..."
if [[ "$MOVE_BROKEN" == true ]]; then
    # Исключаем папку broken из поиска
    find "$SEARCH_DIR" -type f \( $FIND_CONDITION \) -not -path "$BROKEN_DIR/*" -print0 > "$temp_file_list"
else
    find "$SEARCH_DIR" -type f \( $FIND_CONDITION \) -print0 > "$temp_file_list"
fi

# Отладочная информация
echo "Используемая команда find:"
if [[ "$MOVE_BROKEN" == true ]]; then
    echo "find \"$SEARCH_DIR\" -type f \\( $FIND_CONDITION \\) -not -path \"$BROKEN_DIR/*\" -print0"
else
    echo "find \"$SEARCH_DIR\" -type f \\( $FIND_CONDITION \\) -print0"
fi

# Считаем общее количество файлов
total_files_count=$(grep -c $'\0' < "$temp_file_list")

if [[ $total_files_count -eq 0 ]]; then
    echo "Видео файлы не найдены в директории: $SEARCH_DIR"
    rm -f "$temp_file_list"
    exit 0
fi

echo "Найдено файлов: $total_files_count"
if [[ "$FULL_CHECK" == true ]]; then
    echo "Режим: полная проверка файлов"
else
    echo "Режим: быстрая проверка заголовков"
fi
if [[ "$MOVE_BROKEN" == true ]]; then
    echo "Поврежденные файлы будут перемещены в: $BROKEN_DIR"
fi
echo ""

# Проверяем каждый файл
while IFS= read -r -d '' file; do
    ((total_files++))
    
    # Создаем временный файл для вывода ошибок ffmpeg
    temp_error=$(mktemp)
    
    # Проверяем файл с помощью ffmpeg
    if [[ "$FULL_CHECK" == true ]]; then
        # Полная проверка файла (медленнее)
        if ffmpeg -v error -i "$file" -f null - 2>"$temp_error" >/dev/null; then
            if [[ -s "$temp_error" ]]; then
                # Файл проигрывается, но есть предупреждения
                echo -e "${YELLOW}ПРЕДУПРЕЖДЕНИЕ${NC}: $file"
                [[ -n "$OUTPUT_FILE" ]] && echo "ПРЕДУПРЕЖДЕНИЕ: $file" >> "$OUTPUT_FILE"
                ((warning_files++))
            else
                # Файл полностью валиден
                echo -e "${GREEN}ВАЛИДЕН${NC}: $file"
                [[ -n "$OUTPUT_FILE" ]] && echo "ВАЛИДЕН: $file" >> "$OUTPUT_FILE"
                ((valid_files++))
            fi
        else
            # Файл поврежден
            echo -e "${RED}ПОВРЕЖДЕН${NC}: $file"
            [[ -n "$OUTPUT_FILE" ]] && echo "ПОВРЕЖДЕН: $file" >> "$OUTPUT_FILE"
            ((invalid_files++))
            
            # Перемещаем поврежденный файл если включена опция
            if [[ "$MOVE_BROKEN" == true ]]; then
                # Получаем только имя файла без пути
                filename=$(basename "$file")
                # Проверяем, существует ли исходный файл
                if [[ -f "$file" ]]; then
                    if mv "$file" "$BROKEN_DIR/$filename"; then
                        echo -e "${YELLOW}ПЕРЕМЕЩЕН${NC}: $filename -> broken/"
                    else
                        echo -e "${RED}ОШИБКА ПЕРЕМЕЩЕНИЯ${NC}: $file"
                        echo -e "${RED}Исходный файл:${NC} '$file'"
                        echo -e "${RED}Целевая папка:${NC} '$BROKEN_DIR/'"
                    fi
                else
                    echo -e "${RED}ФАЙЛ НЕ НАЙДЕН${NC}: $file"
                fi
            fi
        fi
    else
        # Быстрая проверка только заголовка (по умолчанию)
        if ffmpeg -v error -t 0.1 -i "$file" -f null - 2>"$temp_error" >/dev/null; then
            if [[ -s "$temp_error" ]]; then
                # Файл проигрывается, но есть предупреждения
                echo -e "${YELLOW}ПРЕДУПРЕЖДЕНИЕ${NC}: $file"
                [[ -n "$OUTPUT_FILE" ]] && echo "ПРЕДУПРЕЖДЕНИЕ: $file" >> "$OUTPUT_FILE"
                ((warning_files++))
            else
                # Файл полностью валиден
                echo -e "${GREEN}ВАЛИДЕН${NC}: $file"
                [[ -n "$OUTPUT_FILE" ]] && echo "ВАЛИДЕН: $file" >> "$OUTPUT_FILE"
                ((valid_files++))
            fi
        else
            # Файл поврежден
            echo -e "${RED}ПОВРЕЖДЕН${NC}: $file"
            [[ -n "$OUTPUT_FILE" ]] && echo "ПОВРЕЖДЕН: $file" >> "$OUTPUT_FILE"
            ((invalid_files++))
            
            # Перемещаем поврежденный файл если включена опция
            if [[ "$MOVE_BROKEN" == true ]]; then
                # Получаем только имя файла без пути
                filename=$(basename "$file")
                # Проверяем, существует ли исходный файл
                if [[ -f "$file" ]]; then
                    if mv "$file" "$BROKEN_DIR/$filename"; then
                        echo -e "${YELLOW}ПЕРЕМЕЩЕН${NC}: $filename -> broken/"
                    else
                        echo -e "${RED}ОШИБКА ПЕРЕМЕЩЕНИЯ${NC}: $file"
                        echo -e "${RED}Исходный файл:${NC} '$file'"
                        echo -e "${RED}Целевая папка:${NC} '$BROKEN_DIR/'"
                    fi
                else
                    echo -e "${RED}ФАЙЛ НЕ НАЙДЕН${NC}: $file"
                fi
            fi
        fi
    fi
    
    # Удаляем временный файл
    rm -f "$temp_error"
    
done < "$temp_file_list"

# Очистка временных файлов
rm -f "$temp_file_list"

echo ""

# Устанавливаем код выхода
if [[ $invalid_files -gt 0 ]]; then
    exit 1
else
    exit 0
fi