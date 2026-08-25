// SPDX-License-Identifier: GPL-2.0
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <linux/capability.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <pthread.h>
#include <poll.h>
#include <sys/stat.h>
#include <limits.h>

struct omatunnel_config {
  uint32_t proxy_ip4;
  uint16_t proxy_port;
  uint16_t pad;
};

struct settings {
  char ssh_destination[1024];
  char remote_host[1024];
  char ports[1024];
  unsigned short proxy_port;
};

static volatile sig_atomic_t running = 1;
struct active_connection { uint16_t port; unsigned int count; struct active_connection *next; };
static struct active_connection *active_connections;
static pthread_mutex_t active_connections_lock = PTHREAD_MUTEX_INITIALIZER;
static char status_path[PATH_MAX];
static void stop(int signal_number) { (void)signal_number; running = 0; }

static void fail(const char *message) { fprintf(stderr, "omatunnel-ebpf: %s\n", message); exit(1); }

static void write_status_locked(void) {
  char temporary_path[PATH_MAX + 16];
  snprintf(temporary_path, sizeof(temporary_path), "%s.tmp", status_path);
  FILE *file = fopen(temporary_path, "w");
  if (!file) return;
  fputs("[", file);
  const char *separator = "";
  for (struct active_connection *entry = active_connections; entry; entry = entry->next) {
    fprintf(file, "%s{\"local_port\":%u,\"connections\":%u}", separator, entry->port, entry->count);
    separator = ",";
  }
  fputs("]\n", file);
  fclose(file);
  rename(temporary_path, status_path);
}

static void set_connection_active(uint16_t port, bool active) {
  pthread_mutex_lock(&active_connections_lock);
  struct active_connection **cursor = &active_connections;
  while (*cursor && (*cursor)->port != port) cursor = &(*cursor)->next;
  if (active) {
    struct active_connection *entry = *cursor;
    if (!entry) { entry = calloc(1, sizeof(*entry)); if (entry) { entry->port = port; entry->next = active_connections; active_connections = entry; } }
    if (entry) entry->count++;
  } else if (*cursor) {
    if ((*cursor)->count) (*cursor)->count--;
  }
  write_status_locked();
  pthread_mutex_unlock(&active_connections_lock);
}

static void initialize_status_path(void) {
  const char *configured_status_path = getenv("OMATUNNEL_STATUS_FILE");
  if (configured_status_path && *configured_status_path) {
    size_t configured_length = strnlen(configured_status_path, sizeof(status_path));
    if (configured_length == sizeof(status_path)) fail("status file path is too long");
    memcpy(status_path, configured_status_path, configured_length + 1);
    pthread_mutex_lock(&active_connections_lock); write_status_locked(); pthread_mutex_unlock(&active_connections_lock);
    return;
  }
  const char *runtime = getenv("OMATUNNEL_RUNTIME_DIR");
  char fallback[PATH_MAX];
  if (!runtime || !*runtime) { snprintf(fallback, sizeof(fallback), "/run/user/%u/omatunnel-%u", (unsigned)getuid(), (unsigned)getuid()); runtime = fallback; }
  size_t runtime_length = strnlen(runtime, sizeof(status_path) - sizeof("/on-demand.json"));
  if (runtime[runtime_length]) fail("runtime directory path is too long");
  mkdir(runtime, 0700);
  memcpy(status_path, runtime, runtime_length);
  memcpy(status_path + runtime_length, "/on-demand.json", sizeof("/on-demand.json"));
  pthread_mutex_lock(&active_connections_lock); write_status_locked(); pthread_mutex_unlock(&active_connections_lock);
}

static void parse_settings(const char *path, struct settings *settings) {
  FILE *file = fopen(path, "r");
  char line[1200], key[128], value[1024];
  if (!file) fail("cannot read configuration");
  settings->proxy_port = 46173;
  while (fgets(line, sizeof(line), file)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    if (sscanf(line, "%127[^=]=%1023s", key, value) != 2) fail("invalid configuration line");
    if (!strcmp(key, "ssh_destination")) snprintf(settings->ssh_destination, sizeof(settings->ssh_destination), "%s", value);
    else if (!strcmp(key, "remote_host")) snprintf(settings->remote_host, sizeof(settings->remote_host), "%s", value);
    else if (!strcmp(key, "ports")) snprintf(settings->ports, sizeof(settings->ports), "%s", value);
    else if (!strcmp(key, "proxy_port")) settings->proxy_port = (unsigned short)strtoul(value, NULL, 10);
  }
  fclose(file);
  if (!settings->ssh_destination[0] || !settings->remote_host[0] || !settings->ports[0] || !settings->proxy_port) fail("missing Default destination, remote host, ports, or valid proxy_port");
}

static void write_all(int destination, const char *buffer, size_t length) {
  while (length) { ssize_t written = write(destination, buffer, length); if (written <= 0) return; buffer += written; length -= (size_t)written; }
}

/*
 * The loader needs BPF capabilities for the lifetime of the proxy: it reads
 * and deletes entries from the BPF maps while handling connections.  OpenSSH
 * does not.  In particular, OpenSSH may run a user-controlled ProxyCommand,
 * so make every SSH child entirely unprivileged before it can consult SSH
 * configuration.
 */
static void drop_capabilities_for_ssh(void) {
  struct __user_cap_header_struct header = { .version = _LINUX_CAPABILITY_VERSION_3, .pid = 0 };
  struct __user_cap_data_struct data[2] = {};

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
      prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) ||
      syscall(SYS_capset, &header, &data)) {
    perror("[DEBUG-omatunnel-handoff] cannot drop SSH child capabilities");
    _exit(126);
  }
}

struct copy_context { int source; int destination; };
static void *copy_stream(void *argument) {
  struct copy_context *context = argument; char buffer[65536]; ssize_t read_count;
  while ((read_count = read(context->source, buffer, sizeof(buffer))) > 0) write_all(context->destination, buffer, (size_t)read_count);
  shutdown(context->destination, SHUT_WR);
  return NULL;
}

struct client_key { uint32_t address; uint32_t port; };
struct client_context { int client; int originals_fd; struct settings settings; };
static void *handle_client(void *argument) {
  struct client_context *context = argument; uint16_t original_port; bool tracked = false; struct sockaddr_in peer; socklen_t peer_size = sizeof(peer);
  if (getpeername(context->client, (struct sockaddr *)&peer, &peer_size)) { fprintf(stderr, "[DEBUG-omatunnel-handoff] getpeername failed\n"); goto done; }
  struct client_key client = { .address = peer.sin_addr.s_addr, .port = ntohs(peer.sin_port) };
  if (bpf_map_lookup_elem(context->originals_fd, &client, &original_port)) { fprintf(stderr, "[DEBUG-omatunnel-handoff] no original-port entry for client port %u\n", client.port); goto done; }
  bpf_map_delete_elem(context->originals_fd, &client);
  char target[1100]; snprintf(target, sizeof(target), "%s:%u", context->settings.remote_host, ntohs(original_port));
  int to_child[2], from_child[2]; if (pipe(to_child) || pipe(from_child)) { fprintf(stderr, "[DEBUG-omatunnel-handoff] pipe failed\n"); goto done; }
  pid_t child = fork(); if (child < 0) { fprintf(stderr, "[DEBUG-omatunnel-handoff] fork failed\n"); goto done; }
  if (!child) {
    dup2(to_child[0], STDIN_FILENO); dup2(from_child[1], STDOUT_FILENO);
    close(to_child[1]); close(from_child[0]);
    drop_capabilities_for_ssh();
    execlp("ssh", "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1", "-W", target, context->settings.ssh_destination, (char *)NULL);
    perror("[DEBUG-omatunnel-handoff] ssh exec failed");
    _exit(127);
  }
  close(to_child[0]); close(from_child[1]);
  set_connection_active(ntohs(original_port), true); tracked = true;
  struct copy_context upload = { context->client, to_child[1] }, download = { from_child[0], context->client };
  pthread_t upload_thread, download_thread;
  pthread_create(&upload_thread, NULL, copy_stream, &upload); pthread_create(&download_thread, NULL, copy_stream, &download);
  pthread_join(upload_thread, NULL); close(to_child[1]); pthread_join(download_thread, NULL); close(from_child[0]);
  kill(child, SIGTERM); waitpid(child, NULL, 0);
done:
  if (tracked) set_connection_active(ntohs(original_port), false);
  close(context->client); free(context); return NULL;
}

static void serve_proxy(int originals_fd, const struct settings *settings) {
  int listener = socket(AF_INET, SOCK_STREAM, 0), reuse = 1;
  struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK), .sin_port = htons(settings->proxy_port) };
  if (listener < 0 || setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) || bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 64)) fail("cannot listen for redirected connections");
  while (running) {
    struct pollfd ready = { .fd = listener, .events = POLLIN };
    int poll_result = poll(&ready, 1, 250);
    if (!running) break;
    if (poll_result < 0) { if (errno == EINTR) continue; fail("proxy poll failed"); }
    if (!poll_result) continue;
    int client = accept(listener, NULL, NULL); if (client < 0) { if (errno == EINTR) continue; fail("proxy accept failed"); }
    struct client_context *context = calloc(1, sizeof(*context)); if (!context) { close(client); continue; }
    context->client = client; context->originals_fd = originals_fd; context->settings = *settings;
    pthread_t thread; if (!pthread_create(&thread, NULL, handle_client, context)) pthread_detach(thread); else { close(client); free(context); }
  }
  close(listener);
}

static void allow_ports(int map_fd, const char *specification) {
  char copy[1024], *item, *save = NULL;
  snprintf(copy, sizeof(copy), "%s", specification);
  for (item = strtok_r(copy, ",", &save); item; item = strtok_r(NULL, ",", &save)) {
    char *dash = strchr(item, '-');
    unsigned long first = strtoul(item, NULL, 10), last = dash ? strtoul(dash + 1, NULL, 10) : first;
    if (!first || first > last || last > 65535) fail("invalid ports");
    for (uint32_t port = (uint32_t)first; port <= last; port++) {
      uint8_t enabled = 1;
      if (bpf_map_update_elem(map_fd, &port, &enabled, BPF_ANY)) fail("cannot populate allowed ports");
    }
  }
}

int main(int argc, char **argv) {
  bool serve = argc == 4 && !strcmp(argv[1], "--serve");
  if (argc != 4 || (strcmp(argv[1], "--check") && !serve)) {
    fprintf(stderr, "usage: %s --check|--serve <bpf-object> <config>\n", argv[0]);
    return 2;
  }
  struct settings settings = {};
  parse_settings(argv[3], &settings);
  initialize_status_path();
  struct bpf_object *object = bpf_object__open_file(argv[2], NULL);
  if (!object) fail("cannot open BPF object");
  if (bpf_object__load(object)) fail("kernel rejected BPF program");
  int config_fd = bpf_object__find_map_fd_by_name(object, "config");
  int ports_fd = bpf_object__find_map_fd_by_name(object, "allowed_ports");
  int originals_fd = bpf_object__find_map_fd_by_name(object, "original_ports_by_client");
  if (config_fd < 0 || ports_fd < 0 || originals_fd < 0) fail("required BPF map is missing");
  uint32_t zero = 0;
  struct omatunnel_config configuration = { .proxy_ip4 = htonl(INADDR_LOOPBACK), .proxy_port = htons(settings.proxy_port) };
  if (bpf_map_update_elem(config_fd, &zero, &configuration, BPF_ANY)) fail("cannot configure BPF program");
  allow_ports(ports_fd, settings.ports);
  int cgroup = open("/sys/fs/cgroup", O_RDONLY | O_DIRECTORY);
  if (cgroup < 0) fail("cannot open cgroup root");
  struct bpf_program *program = bpf_object__find_program_by_name(object, "omatunnel_connect4");
  struct bpf_link *link = bpf_program__attach_cgroup(program, cgroup);
  if (!link) fail("cannot attach to cgroup root");
  struct bpf_program *sockops = bpf_object__find_program_by_name(object, "omatunnel_sockops");
  struct bpf_link *sockops_link = bpf_program__attach_cgroup(sockops, cgroup);
  if (!sockops_link) fail("cannot attach socket lifecycle tracking");
  puts("BPF program loaded, verified, and attached to the cgroup root.");
  signal(SIGINT, stop); signal(SIGTERM, stop);
  if (serve) serve_proxy(originals_fd, &settings); else while (running) pause();
  bpf_link__destroy(link);
  bpf_link__destroy(sockops_link);
  bpf_object__close(object);
  close(cgroup);
  return 0;
}
