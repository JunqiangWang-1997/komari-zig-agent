#!/bin/sh
# 重新签发测试用 CA 证书。
#
# 背景：test/testdata_ca_root.pem 与 test/testdata_ca_dir.pem 是
# `test/raw_conn_test.zig` 通过 @embedFile 嵌入的 CA bundle 加载夹具。
# 二者此前由手工命令生成，ca_root.pem 只签发了 24 小时有效期，过期后
# `std.crypto.Certificate.Bundle` 会静默拒收，导致 `zig build test` 失败。
#
# 本脚本签发 10 年有效期、notBefore 回拨 1 天的自签 CA，兼顾 CI 时钟漂移。
# 用法：sh scripts/gen_test_certs.sh
set -eu

out_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/test
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

# 回拨 1 天，容忍构建机时钟略慢于签发机的情况。
not_before=$(date -u -d '1 day ago' +%Y%m%d%H%M%SZ)
not_after=$(date -u -d '10 years' +%Y%m%d%H%M%SZ)

# 自签 CA 扩展：CA:TRUE 为关键扩展，SKI/AKI 供 Bundle 归组使用。
cat >"$tmp_dir/v3_ca.cnf" <<'EOF'
[ v3_ca ]
basicConstraints = critical,CA:TRUE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

# $1=common name  $2=输出文件
gen_ca() {
    cn=$1
    out=$2
    openssl genrsa -out "$tmp_dir/$cn.key" 2048 2>/dev/null
    openssl req -new -key "$tmp_dir/$cn.key" -subj "/CN=$cn" \
        -out "$tmp_dir/$cn.csr"
    openssl x509 -req -in "$tmp_dir/$cn.csr" -signkey "$tmp_dir/$cn.key" \
        -sha256 -not_before "$not_before" -not_after "$not_after" \
        -set_serial "0x$(openssl rand -hex 8)" \
        -extfile "$tmp_dir/v3_ca.cnf" -extensions v3_ca \
        -out "$tmp_dir/$cn.crt" 2>/dev/null
    cp "$tmp_dir/$cn.crt" "$out"
    openssl x509 -in "$out" -noout -subject -dates
}

gen_ca test "$out_dir/testdata_ca_root.pem"
gen_ca test-dir "$out_dir/testdata_ca_dir.pem"
