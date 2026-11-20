#!/bin/sh
# Runs as the init container: installs ttyd, k9s and vim into /tools for this node's CPU architecture.
set -eu
cd /tools
case "$(uname -m)" in
  aarch64)
    ttyd_arch=aarch64 ttyd_sha=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
    k9s_arch=arm64 k9s_sha=3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c ;;
  x86_64)
    ttyd_arch=x86_64 ttyd_sha=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
    k9s_arch=amd64 k9s_sha=c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
wget -qO ttyd "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.$ttyd_arch"
wget -qO k9s.tgz "https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_$k9s_arch.tar.gz"
printf '%s  %s\n' "$ttyd_sha" ttyd "$k9s_sha" k9s.tgz | sha256sum -c
tar xzf k9s.tgz k9s && rm k9s.tgz && chmod 0555 ttyd k9s

# vim for k9s edit: apk fetch checks Alpine's package signatures and needs no root.
mkdir apk vimroot && (cd apk && apk fetch --no-cache -q -R vim)
for p in apk/*.apk; do tar xzf "$p" -C vimroot 2>/dev/null; done && rm -r apk
cat > vim <<'VIM'
#!/bin/sh
export LD_LIBRARY_PATH=/tools/vimroot/usr/lib TERMINFO=/tools/vimroot/usr/share/terminfo
export VIMRUNTIME=$(echo /tools/vimroot/usr/share/vim/vim9*)
exec /tools/vimroot/usr/bin/vim "$@"
VIM
chmod 0555 vim

# k9s needs a named context; the token file is the projected ServiceAccount token, which the kubelet rotates.
cat > kubeconfig <<KC
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
users:
  - name: k9s
    user:
      tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
contexts:
  - name: $CONTEXT_NAME
    context: { cluster: in-cluster, user: k9s, namespace: default }
current-context: $CONTEXT_NAME
KC
