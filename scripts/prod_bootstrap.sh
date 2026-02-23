#!/usr/bin/env sh

# Copyright (C) 2026 Fluxer Contributors
#
# This file is part of Fluxer.
#
# Fluxer is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Fluxer is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Fluxer. If not, see <https://www.gnu.org/licenses/>.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { printf "%b\n" "${GREEN}[INFO]${NC} $1"; }
warn() { printf "%b\n" "${YELLOW}[WARN]${NC} $1"; }
error() { printf "%b\n" "${RED}[ERROR]${NC} $1"; }
header() { printf "%b\n" "${CYAN}$1${NC}"; }

CONFIG_DIR="$REPO_ROOT/config"
CONFIG_PATH="$CONFIG_DIR/config.json"
TEMPLATE_PATH="$CONFIG_DIR/config.production.template.json"
ENV_FILE="$REPO_ROOT/.env"

# --- Dependency checks ---

check_dependencies() {
    missing=""
    for cmd in jq openssl node; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        error "Missing required tools:$missing"
        error "Install them and re-run this script."
        exit 1
    fi
}

# --- Secret generation helpers ---

random_hex() {
    byte_count="$1"
    node - "$byte_count" <<'NODE'
const {randomBytes} = require('node:crypto');
const byteCount = Number(process.argv[2]);
if (!Number.isInteger(byteCount) || byteCount <= 0) {
	process.exit(1);
}
process.stdout.write(randomBytes(byteCount).toString('hex'));
NODE
}

generate_vapid_keypair() {
    node - <<'NODE'
const {generateKeyPairSync} = require('node:crypto');
const {privateKey, publicKey} = generateKeyPairSync('ec', {namedCurve: 'prime256v1'});
const publicJwk = publicKey.export({format: 'jwk'});
const privateJwk = privateKey.export({format: 'jwk'});
const publicRaw = Buffer.concat([
	Buffer.from([0x04]),
	Buffer.from(publicJwk.x, 'base64url'),
	Buffer.from(publicJwk.y, 'base64url'),
]);
process.stdout.write(
	JSON.stringify({
		public_key: publicRaw.toString('base64url'),
		private_key: privateJwk.d,
	})
);
NODE
}

# --- Config setup ---

setup_config() {
    if [ -f "$CONFIG_PATH" ]; then
        info "Config file already exists at $CONFIG_PATH"
        return 0
    fi

    if [ ! -f "$TEMPLATE_PATH" ]; then
        error "Production template not found: $TEMPLATE_PATH"
        exit 1
    fi

    info "Creating config from production template..."
    cp "$TEMPLATE_PATH" "$CONFIG_PATH"
}

# --- Domain configuration ---

configure_domain() {
    domain="${FLUXER_DOMAIN:-}"
    scheme="${FLUXER_SCHEME:-https}"
    port="${FLUXER_PORT:-443}"

    if [ -z "$domain" ]; then
        printf "Enter your domain (e.g. chat.example.com): "
        read -r domain
    fi

    if [ -z "$domain" ]; then
        error "Domain is required. Set FLUXER_DOMAIN or enter it when prompted."
        exit 1
    fi

    info "Configuring domain: ${scheme}://${domain}:${port}"

    temp_config="$CONFIG_PATH.tmp"
    jq \
        --arg domain "$domain" \
        --arg scheme "$scheme" \
        --argjson port "$port" \
        '.domain.base_domain = $domain |
         .domain.public_scheme = $scheme |
         .domain.public_port = $port' \
        "$CONFIG_PATH" > "$temp_config" && mv "$temp_config" "$CONFIG_PATH"
}

# --- Secret generation ---

generate_secrets() {
    info "Generating production secrets..."

    s3_access_key_id=$(random_hex 16)
    s3_secret_access_key=$(random_hex 32)
    media_proxy_secret_key=$(random_hex 32)
    admin_secret_key_base=$(random_hex 32)
    admin_oauth_client_secret=$(random_hex 32)
    marketing_secret_key_base=$(random_hex 32)
    gateway_admin_reload_secret=$(random_hex 32)
    sudo_mode_secret=$(random_hex 32)
    connection_initiation_secret=$(random_hex 32)
    meilisearch_api_key=$(random_hex 32)

    temp_config="$CONFIG_PATH.tmp"
    jq \
        --arg s3_access_key_id "$s3_access_key_id" \
        --arg s3_secret_access_key "$s3_secret_access_key" \
        --arg media_proxy_secret_key "$media_proxy_secret_key" \
        --arg admin_secret_key_base "$admin_secret_key_base" \
        --arg admin_oauth_client_secret "$admin_oauth_client_secret" \
        --arg marketing_secret_key_base "$marketing_secret_key_base" \
        --arg gateway_admin_reload_secret "$gateway_admin_reload_secret" \
        --arg sudo_mode_secret "$sudo_mode_secret" \
        --arg connection_initiation_secret "$connection_initiation_secret" \
        --arg meilisearch_api_key "$meilisearch_api_key" \
        '
        # Only replace placeholder values, not already-configured secrets
        def replace_placeholder($val; $placeholders):
            if (. == null or . == "" or (. | test("^(GENERATE_|YOUR_)"))) then $val else . end;

        .s3.access_key_id |= replace_placeholder($s3_access_key_id; null) |
        .s3.secret_access_key |= replace_placeholder($s3_secret_access_key; null) |
        .services.media_proxy.secret_key |= replace_placeholder($media_proxy_secret_key; null) |
        .services.admin.secret_key_base |= replace_placeholder($admin_secret_key_base; null) |
        .services.admin.oauth_client_secret |= replace_placeholder($admin_oauth_client_secret; null) |
        .services.marketing.secret_key_base |= replace_placeholder($marketing_secret_key_base; null) |
        .services.gateway.admin_reload_secret |= replace_placeholder($gateway_admin_reload_secret; null) |
        .auth.sudo_mode_secret |= replace_placeholder($sudo_mode_secret; null) |
        .auth.connection_initiation_secret |= replace_placeholder($connection_initiation_secret; null) |
        .integrations.search.api_key |= replace_placeholder($meilisearch_api_key; null)
        ' \
        "$CONFIG_PATH" > "$temp_config" && mv "$temp_config" "$CONFIG_PATH"

    info "Secrets generated and written to config"
}

# --- VAPID keys ---

generate_vapid() {
    current_public=$(jq -r '.auth.vapid.public_key // empty' "$CONFIG_PATH" 2>/dev/null || true)
    current_private=$(jq -r '.auth.vapid.private_key // empty' "$CONFIG_PATH" 2>/dev/null || true)

    if [ -n "$current_public" ] && [ -n "$current_private" ] && \
       ! echo "$current_public" | grep -q "^YOUR_"; then
        info "VAPID keys already configured"
        return 0
    fi

    info "Generating VAPID keypair..."
    vapid_json=$(generate_vapid_keypair)
    pub=$(printf '%s' "$vapid_json" | jq -r '.public_key')
    priv=$(printf '%s' "$vapid_json" | jq -r '.private_key')

    temp_config="$CONFIG_PATH.tmp"
    jq \
        --arg pub "$pub" \
        --arg priv "$priv" \
        '.auth.vapid.public_key = $pub |
         .auth.vapid.private_key = $priv' \
        "$CONFIG_PATH" > "$temp_config" && mv "$temp_config" "$CONFIG_PATH"

    info "VAPID keys generated"
}

# --- LiveKit config ---

generate_livekit_config() {
    livekit_config="$CONFIG_DIR/livekit.yaml"
    template="$CONFIG_DIR/livekit.example.yaml"

    if [ -f "$livekit_config" ]; then
        info "LiveKit config already exists"
        return 0
    fi

    if [ ! -f "$template" ]; then
        warn "LiveKit example config not found, skipping"
        return 0
    fi

    voice_api_key=$(jq -r '.integrations.voice.api_key // empty' "$CONFIG_PATH" 2>/dev/null || true)
    voice_api_secret=$(jq -r '.integrations.voice.api_secret // empty' "$CONFIG_PATH" 2>/dev/null || true)

    if [ -z "$voice_api_key" ] || echo "$voice_api_key" | grep -q "^YOUR_"; then
        voice_api_key=$(random_hex 16)
        voice_api_secret=$(random_hex 32)

        temp_config="$CONFIG_PATH.tmp"
        jq \
            --arg key "$voice_api_key" \
            --arg secret "$voice_api_secret" \
            '.integrations.voice.api_key = $key |
             .integrations.voice.api_secret = $secret' \
            "$CONFIG_PATH" > "$temp_config" && mv "$temp_config" "$CONFIG_PATH"
    fi

    domain=$(jq -r '.domain.base_domain // "localhost"' "$CONFIG_PATH")
    webhook_url="http://fluxer_server:8080/api/webhooks/livekit"

    sed -e "s|<replace-with-api-key>|$voice_api_key|g" \
        -e "s|<replace-with-api-secret>|$voice_api_secret|g" \
        "$template" > "$livekit_config"

    info "LiveKit config generated at: $livekit_config"
}

# --- .env file for docker compose ---

generate_env_file() {
    if [ -f "$ENV_FILE" ]; then
        info ".env file already exists, updating missing values..."
    fi

    meili_key=$(jq -r '.integrations.search.api_key // empty' "$CONFIG_PATH" 2>/dev/null || true)

    # Write .env, preserving any existing user customizations
    env_content=""

    append_env() {
        key="$1"
        value="$2"
        if [ -f "$ENV_FILE" ] && grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            return 0
        fi
        env_content="${env_content}${key}=${value}\n"
    }

    append_env "MEILI_MASTER_KEY" "$meili_key"

    if [ -n "$env_content" ]; then
        printf '%b' "$env_content" >> "$ENV_FILE"
        info ".env file updated"
    else
        info ".env file already complete"
    fi
}

# --- Main ---

main() {
    echo ""
    header "========================================="
    header "  Fluxer Production Bootstrap"
    header "========================================="
    echo ""

    check_dependencies
    setup_config
    configure_domain
    generate_secrets
    generate_vapid
    generate_livekit_config
    generate_env_file

    echo ""
    info "Production bootstrap complete!"
    echo ""
    info "Next steps:"
    info "  1. Review config/config.json and adjust as needed"
    info "  2. Start services:  docker compose up -d"
    info "  3. (Optional) Enable search:  docker compose --profile search up -d"
    info "  4. (Optional) Enable voice:   docker compose --profile voice up -d"
    info "  5. Check health:   curl http://localhost:8080/_health"
    echo ""
}

main "$@"
