// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <linux/in.h>
#include <linux/socket.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#define OMATUNNEL_AF_INET 2

struct omatunnel_config {
  __u32 proxy_ip4;
  __u16 proxy_port;
  __u16 pad;
};

struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, struct omatunnel_config);
} config SEC(".maps");

struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 65536);
  __type(key, __u32);
  __type(value, __u8);
} allowed_ports SEC(".maps");

struct {
  __uint(type, BPF_MAP_TYPE_LRU_HASH);
  __uint(max_entries, 4096);
  __type(key, __u64);
  __type(value, __u16);
} original_ports_by_cookie SEC(".maps");

struct client_key {
  __u32 address;
  __u32 port;
};

struct {
  __uint(type, BPF_MAP_TYPE_LRU_HASH);
  __uint(max_entries, 4096);
  __type(key, struct client_key);
  __type(value, __u16);
} original_ports_by_client SEC(".maps");

SEC("cgroup/connect4")
int omatunnel_connect4(struct bpf_sock_addr *ctx) {
  __u32 zero = 0;
  struct omatunnel_config *configuration = bpf_map_lookup_elem(&config, &zero);
  if (!configuration || ctx->protocol != IPPROTO_TCP || ctx->user_ip4 != bpf_htonl(INADDR_LOOPBACK))
    return 1;

  __u32 port = bpf_ntohs(ctx->user_port);
  __u8 *allowed = bpf_map_lookup_elem(&allowed_ports, &port);
  if (!allowed || !*allowed || ctx->user_port == configuration->proxy_port)
    return 1;

  struct bpf_sock_tuple tuple = {};
  tuple.ipv4.daddr = ctx->user_ip4;
  tuple.ipv4.dport = ctx->user_port;
  struct bpf_sock *listener = bpf_sk_lookup_tcp(ctx, &tuple, sizeof(tuple.ipv4), -1, 0);
  if (listener) {
    bpf_sk_release(listener);
    return 1;
  }

  __u64 cookie = bpf_get_socket_cookie(ctx);
  __u16 original_port = ctx->user_port;
  if (bpf_map_update_elem(&original_ports_by_cookie, &cookie, &original_port, BPF_ANY))
    return 1;
  ctx->user_ip4 = configuration->proxy_ip4;
  ctx->user_port = configuration->proxy_port;
  return 1;
}

SEC("sockops")
int omatunnel_sockops(struct bpf_sock_ops *ctx) {
  if (ctx->op != BPF_SOCK_OPS_TCP_CONNECT_CB || ctx->family != OMATUNNEL_AF_INET)
    return 1;
  __u64 cookie = bpf_get_socket_cookie(ctx);
  __u16 *original_port = bpf_map_lookup_elem(&original_ports_by_cookie, &cookie);
  if (!original_port)
    return 1;
  struct client_key client = { .address = ctx->local_ip4, .port = ctx->local_port };
  bpf_map_update_elem(&original_ports_by_client, &client, original_port, BPF_ANY);
  bpf_map_delete_elem(&original_ports_by_cookie, &cookie);
  return 1;
}

char LICENSE[] SEC("license") = "GPL";
