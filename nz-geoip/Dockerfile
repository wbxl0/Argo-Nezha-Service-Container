# Overlay on the panel image used by the nz-aoi Unikraft instance.
# Only the dashboard download source changes (official -> this fork), so a
# restart of the container fetches the binary we rebuild on demand instead of
# the official v2.2.10 build whose GeoIP database is frozen at its build date.
FROM ghcr.io/aoi675145/nz-aoi:latest

RUN set -eux; \
    sed -i 's#github\.com/nezhahq/nezha/releases#github.com/wbxl0/Argo-Nezha-Service-Container/releases#g' /app/start.sh; \
    sed -i 's#"nezhahq/nezha" "\$dash_tag"#"wbxl0/Argo-Nezha-Service-Container" "$dash_tag"#g' /app/start.sh; \
    grep -n 'Argo-Nezha-Service-Container' /app/start.sh; \
    test "$(grep -c 'nezhahq/nezha' /app/start.sh)" = "0"
