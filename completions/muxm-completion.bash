# =============================================================================
#  muxm — Bash/Zsh tab completion  (installed by muxm --install-completions)
# =============================================================================

_muxm_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # ---- Flags that take a specific set of values ----
    case "$prev" in
        --profile)
            COMPREPLY=( $(compgen -W "archive hdr10-hq atv-directplay-hq atv-directplay-animation streaming-hevc av1-hq streaming-av1 animation universal youtube-upload" -- "$cur") )
            return ;;
        --video-codec)
            COMPREPLY=( $(compgen -W "libx265 libx264 libsvt-av1 libaom-av1" -- "$cur") )
            return ;;
        --hw-accel)
            COMPREPLY=( $(compgen -W "none auto videotoolbox nvenc" -- "$cur") )
            return ;;
        --output-ext)
            COMPREPLY=( $(compgen -W "mp4 mkv m4v mov" -- "$cur") )
            return ;;
        -p|--preset)
            COMPREPLY=( $(compgen -W "ultrafast superfast veryfast faster fast medium slow slower veryslow placebo" -- "$cur") )
            return ;;
        --ocr-tool)
            COMPREPLY=( $(compgen -W "pgsrip sub2srt" -- "$cur") )
            return ;;
        --ffmpeg-loglevel|--ffprobe-loglevel)
            COMPREPLY=( $(compgen -W "quiet panic fatal error warning info verbose debug trace" -- "$cur") )
            return ;;
        --create-config|--force-create-config)
            COMPREPLY=( $(compgen -W "system user project" -- "$cur") )
            return ;;
        --checksum-algo)
            COMPREPLY=( $(compgen -W "sha256 blake2b auto" -- "$cur") )
            return ;;

        # Flags that take a free-form value — offer no completion, fall through to files
        --crf|--stereo-bitrate|--threads|-l|--level|--x265-params|--x264-params|\
        --av1-params|--av1-maxrate|--av1-bufsize|--hw-accel-quality|\
        --audio-track|--audio-lang-pref|--audio-force-codec|--audio-force-bitrate|\
        --max-copy-bitrate|--sub-lang-pref|--ocr-lang|--ext-subs-dir)
            COMPREPLY=()
            return ;;
    esac

    # ---- After --create-config <scope>, offer profile names ----
    if (( COMP_CWORD >= 3 )); then
        local pprev="${COMP_WORDS[COMP_CWORD-2]}"
        if [[ "$pprev" == "--create-config" || "$pprev" == "--force-create-config" ]]; then
            COMPREPLY=( $(compgen -W "archive hdr10-hq atv-directplay-hq atv-directplay-animation streaming-hevc av1-hq streaming-av1 animation universal youtube-upload" -- "$cur") )
            return
        fi
    fi

    # ---- If typing a flag, complete from all known flags ----
    if [[ "$cur" == -* ]]; then
        local flags="
            -h --help -V --version
            --profile --dry-run --print-effective-config
            --install-dependencies --install-man --uninstall-man
            --install-completions --uninstall-completions
            --setup
            --create-config --force-create-config

            --crf -p --preset --x265-params --x264-params -l --level
            --av1-params --av1-maxrate --av1-bufsize
            --hw-accel --hw-accel-quality --hw-accel-allow-sw --no-hw-accel-allow-sw
            --video-codec --tonemap --no-tonemap
            --sdr-force-10bit --no-sdr-force-10bit
            --conservative-vbv --no-conservative-vbv
            --dv --no-dv --allow-dv-fallback --no-allow-dv-fallback
            --dv-convert-p81 --no-dv-convert-p81
            --video-copy-if-compliant --no-video-copy-if-compliant
            --max-copy-bitrate

            --audio-track --audio-lang-pref
            --prefer-stereo --no-prefer-stereo --stereo-fallback --no-stereo-fallback --stereo-bitrate
            --audio-force-codec --audio-force-bitrate
            --audio-lossless-passthrough --no-audio-lossless-passthrough
            --audio-titles --no-audio-titles

            --sub-burn-forced --no-sub-burn-forced
            --sub-export-external --no-sub-export-external
            --sub-preserve-format --no-sub-preserve-format
            --sub-preserve-bitmap --no-sub-preserve-bitmap
            --sub-lang-pref --no-sub-sdh --no-subtitles
            --ocr-lang --no-ocr --ocr-tool
            --ext-subs --no-ext-subs --ext-subs-dir
            --sub-sole-ext-fallback --no-sub-sole-ext-fallback

            --skip-audio --skip-subs

            --output-ext
            --keep-chapters --no-keep-chapters
            --strip-metadata --no-strip-metadata
            --profile-comment --no-profile-comment
            --skip-if-ideal --no-skip-if-ideal
            --report-json --no-report-json
            --checksum --no-checksum --checksum-algo
            --disk-check --no-disk-check
            --no-overwrite
            --replace-source --force-replace-source

            -k --keep-temp -K --keep-temp-always
            --ffmpeg-loglevel --ffprobe-loglevel --no-hide-banner
            --threads
        "
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        return
    fi

    # ---- Default: complete with media files ----
    # Uses typeset -l for case-insensitive extension matching (works in both
    # bash 4+ and zsh) and a while-read loop instead of mapfile (bash-only).
    # Avoids shopt/extglob which are unavailable in zsh even with bashcompinit.
    COMPREPLY=()
    local _f
    local _ext_lower
    typeset -l _ext_lower  # auto-lowercase on assignment (portable bash+zsh)
    while IFS= read -r _f; do
        _ext_lower="${_f##*.}"
        case "$_ext_lower" in
            mkv|mp4|m4v|mov|avi|ts|wmv|flv|webm) COMPREPLY+=("$_f") ;;
        esac
    done < <(compgen -f -- "$cur")
    # Also allow directories for navigation
    while IFS= read -r _f; do
        COMPREPLY+=("$_f")
    done < <(compgen -d -- "$cur")
}

# ---- Zsh compatibility ----
# If running in zsh, enable bash completion emulation BEFORE calling `complete`.
# Without this, the unconditional `complete` below would error in zsh.
if [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz bashcompinit && bashcompinit
fi

complete -o filenames -o bashdefault -F _muxm_completions muxm