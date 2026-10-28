#!/usr/bin/env bash
# Choix des registres d'un build open-ent : voir action.yml.
#
# npm   : un seul registre par scope, pas de repli natif. On sonde, on retient la
#         première source disponible dans l'ordre voulu, et si c'est Nexus on fait
#         pointer @open-ent dessus dans le .npmrc (et dans le lockfile, qui fige les URL
#         GitHub des tarballs). L'identifiant Nexus est référencé par ${OEM_NEXUS_NPM_AUTH},
#         jamais écrit en clair.
# Maven : repli natif. Les deux dépôts sont déclarés dans l'ordre voulu (seulement
#         ceux qui répondent) ; Maven passe au suivant, artefact par artefact.
set -euo pipefail

NPM_REG="${NEXUS_URL%/}/repository/npm-passtech/"
MVN_NEXUS="${NEXUS_URL%/}/repository/maven-public/"
BASIC="$(printf '%s:%s' "$NEXUS_USER" "$NEXUS_PASSWORD" | base64 -w0)"
echo "::add-mask::${BASIC}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null || echo 000; }
up() { [[ "$1" == 200 ]]; }
join() { local sep="$1" out="" x; shift; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }

if [[ -z "$NEXUS_USER" || -z "$NEXUS_PASSWORD" ]]; then
    echo "::warning::Identifiants Nexus vides (secrets NEXUS_USER/NEXUS_PASSWORD du DÉPÔT ?) : Nexus écarté."
    nexus_npm=000; nexus_mvn=000
else
    nexus_npm="$(code -H "Authorization: Basic ${BASIC}" "${NPM_REG}@open-ent%2freact")"
    nexus_mvn="$(code -H "Authorization: Basic ${BASIC}" "${MVN_NEXUS}org/entcore/common/maven-metadata.xml")"
fi
github_npm="$(code -H "Authorization: Bearer ${GH_PKG_TOKEN}" "https://npm.pkg.github.com/@open-ent%2freact")"
github_mvn="$(code -u "${GH_PKG_ACTOR}:${GH_PKG_TOKEN}" "${GITHUB_MAVEN_URL%/}/org/entcore/common/maven-metadata.xml")"
echo "Sondes : npm nexus=${nexus_npm} github=${github_npm} ; maven nexus=${nexus_mvn} github=${github_mvn}"

case "$PREFER" in
    github) ORDER=(github nexus) ;;
    *)      ORDER=(nexus github) ;;
esac

# ── npm ───────────────────────────────────────────────────────────────────────
npm_source=""
if [[ -n "$NPM_DIR" ]]; then
    for s in "${ORDER[@]}"; do
        v="${s}_npm"
        if up "${!v}"; then npm_source="$s"; break; fi
    done
    if [[ -z "$npm_source" ]]; then
        echo "::error::Aucun registre npm disponible pour @open-ent (Nexus ${nexus_npm}, GitHub ${github_npm})."
        exit 1
    fi
    if [[ "$npm_source" == nexus ]]; then
        host="${NPM_REG#https:}"
        echo "OEM_NEXUS_NPM_AUTH=${BASIC}" >> "$GITHUB_ENV"
        while IFS= read -r f; do
            grep -q '^@open-ent:registry=' "$f" || continue
            sed -i "s#^@open-ent:registry=.*#@open-ent:registry=${NPM_REG}#" "$f"
            sed -i "\#^${host}:#d" "$f"
            [[ -n "$(tail -c1 "$f")" ]] && echo >> "$f"
            printf '%s:_auth=${OEM_NEXUS_NPM_AUTH}\n' "$host" >> "$f"
            echo "  ${f} : @open-ent → Nexus"
        done < <(find "$NPM_DIR" -maxdepth 2 -name node_modules -prune -o -name .npmrc -type f -print)
        while IFS= read -r f; do
            sed -i -E "s#https://npm\.pkg\.github\.com/download/@open-ent/([^/]+)/([^/]+)/[0-9a-f]{40}#${NPM_REG}@open-ent/\1/-/\1-\2.tgz#g" "$f"
        done < <(find "$NPM_DIR" -maxdepth 2 -name node_modules -prune -o -name pnpm-lock.yaml -type f -print)
    fi
    echo "npm=${npm_source}" >> "$GITHUB_OUTPUT"
fi

# ── Maven ─────────────────────────────────────────────────────────────────────
maven_order=()
for s in "${ORDER[@]}"; do
    v="${s}_mvn"
    up "${!v}" && maven_order+=("$s")
done
if [[ "$MAVEN_SETTINGS" == "true" ]]; then
    if (( ${#maven_order[@]} == 0 )); then
        echo "::error::Aucun dépôt Maven disponible pour org.entcore (Nexus ${nexus_mvn}, GitHub ${github_mvn})."
        exit 1
    fi
    repos=""
    for s in "${maven_order[@]}"; do
        if [[ "$s" == nexus ]]; then
            repos+="<repository><id>pt-public</id><url>${MVN_NEXUS}</url><releases><enabled>true</enabled></releases><snapshots><enabled>true</enabled></snapshots></repository>"
        else
            repos+="<repository><id>github</id><url>${GITHUB_MAVEN_URL}</url><releases><enabled>true</enabled></releases><snapshots><enabled>true</enabled></snapshots></repository>"
        fi
    done
    mkdir -p ~/.m2
    # Serveurs : `github` et `pt-releases` gardent les identifiants des étapes de
    # publication existantes ; `pt-public` sert à la résolution depuis Nexus.
    cat > ~/.m2/settings.xml <<EOF
<settings>
  <servers>
    <server><id>github</id><username>${GH_PKG_ACTOR}</username><password>${GH_PKG_TOKEN}</password></server>
    <server><id>pt-releases</id><username>${NEXUS_USER}</username><password>${NEXUS_PASSWORD}</password></server>
    <server><id>pt-public</id><username>${NEXUS_USER}</username><password>${NEXUS_PASSWORD}</password></server>
  </servers>
  <profiles>
    <profile>
      <id>oem-registries</id>
      <repositories>${repos}</repositories>
    </profile>
  </profiles>
  <activeProfiles><activeProfile>oem-registries</activeProfile></activeProfiles>
</settings>
EOF
    echo "  ~/.m2/settings.xml : org.entcore depuis $(join ' puis ' "${maven_order[@]}")"
fi
echo "maven=$(join , "${maven_order[@]}")" >> "$GITHUB_OUTPUT"

{
    echo "### Registres retenus"
    echo "| | Nexus | GitHub | Retenu |"
    echo "|---|---|---|---|"
    echo "| npm @open-ent | ${nexus_npm} | ${github_npm} | ${npm_source:-—} |"
    echo "| Maven org.entcore | ${nexus_mvn} | ${github_mvn} | $(join ' puis ' "${maven_order[@]}") |"
} >> "$GITHUB_STEP_SUMMARY"
