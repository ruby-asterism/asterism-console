require "test_helper"
require "tmpdir"
require "open3"

# deploy/vps/update.sh with --dry-run, in a throwaway git checkout with the
# tags it needs and a stand-in `docker` on PATH that answers only the
# read-only questions (and logs every call).
class UpdateScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("deploy/vps/update.sh").to_s

  setup do
    @tmp = Dir.mktmpdir("update-script")
    @repo = File.join(@tmp, "asterism-console")
    @vps = File.join(@repo, "deploy/vps")
    FileUtils.mkdir_p(@vps)
    FileUtils.cp(Rails.root.join("deploy/vps/docker-compose.yml"), @vps)
    FileUtils.cp(Rails.root.join("deploy/vps/env.example"), @vps)
    FileUtils.cp(SCRIPT, @vps)
    File.write(File.join(@repo, ".gitignore"), "/deploy/vps/.env\n")
    git("init", "-q", "-b", "main")
    git("add", ".")
    git("-c", "user.name=t", "-c", "user.email=t@example.org", "commit", "-q", "-m", "one")
    git("tag", "v0.1.2")
    git("tag", "v0.1.3")
    git("tag", "v0.1.1")
    @env = File.join(@vps, ".env")
    File.write(@env, "CONSOLE_IMAGE=registry.example.org/asterism-console\nCONSOLE_VERSION=0.1.2\n")
    @bin = File.join(@tmp, "bin")
    @log = File.join(@tmp, "docker.log")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "docker"), <<~SH)
      #!/bin/sh
      echo "$*" >> #{@log}
      case "$*" in
        *config*) echo "name: asterism"; echo "services:" ;;
      esac
      exit 0
    SH
    File.chmod(0o755, File.join(@bin, "docker"))
    File.write(File.join(@bin, "sudo"), "#!/bin/sh\nexec \"$@\"\n") # stands in for sudo without a password
    File.chmod(0o755, File.join(@bin, "sudo"))
  end

  teardown { FileUtils.rm_rf(@tmp) }

  def git(*args) = system("git", "-C", @repo, *args, exception: true)

  def run_script(*args, env: {})
    path = "#{@bin}:#{ENV.fetch('PATH')}"
    Open3.capture2e({ "PATH" => path, "COMPOSE_FILE" => nil, "ASTERISM_SYSTEMD_UNIT" => nil }.merge(env),
                    "sh", File.join(@vps, "update.sh"), *args)
  end

  def lines_matching(out, *patterns)
    patterns.map { |p| out.lines.index { _1.include?(p) } || flunk("no line with #{p.inspect} in:\n#{out}") }
  end

  def assert_unchanged
    assert_includes File.read(@env), "CONSOLE_VERSION=0.1.2"
    assert_equal "main", `git -C #{@repo} symbolic-ref --short HEAD`.strip
    calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []
    assert(calls.all? { _1.match?(/\Acompose .*(version|config)/) }, "docker was asked more than read-only questions:\n#{calls.join("\n")}")
  end

  test "updating: the new files and image first, then the backup with them, the setup, the restart, the check" do
    out, st = run_script("--dry-run", "0.1.3")
    assert st.success?, out
    order = lines_matching(out, "checkout -q v0.1.3", "sed -i s/^CONSOLE_VERSION=.*/CONSOLE_VERSION=0.1.3/",
                           "docker compose pull", "run --rm --no-deps -T console bin/asterism backup --label before-0.1.3 --data-version 0.1.2",
                           "bin/asterism setup", "up -d --remove-orphans", "would wait until every service runs")
    assert_equal order.sort, order
    assert_includes out, "console 0.1.2 -> 0.1.3 (registry.example.org/asterism-console)"
    assert_includes out, "0.1.2 --restore asterism-<time>-0.1.2-before-0.1.3.tar.gz"
    refute_includes out, "systemctl"
    assert_unchanged
  end

  test "going back with --restore: backup and restore on the running version, then the older files" do
    File.write(@env, "CONSOLE_VERSION=0.1.3\n")
    out, st = run_script("--dry-run", "0.1.2", "--restore", "asterism-20261014-030000-0.1.2-before-0.1.3.tar.gz")
    assert st.success?, out
    order = lines_matching(out, "env CONSOLE_VERSION=0.1.2 docker compose pull console",
                           "env CONSOLE_VERSION=0.1.3 docker compose run --rm --no-deps -T console bin/asterism backup --label before-0.1.2 --data-version 0.1.3 --no-rotate",
                           "stop console bridge backup",
                           "env CONSOLE_VERSION=0.1.3 docker compose run --rm --no-deps -T console bin/asterism restore asterism-20261014-030000-0.1.2-before-0.1.3.tar.gz",
                           "checkout -q v0.1.2", "bin/asterism setup", "up -d --remove-orphans")
    assert_equal order.sort, order
    assert_includes out, "ghcr.io/ruby-asterism/asterism-console" # no CONSOLE_IMAGE line: the default
  end

  test "sudo, an include wrapper by COMPOSE_FILE, a systemd unit" do
    out, st = run_script("--dry-run", "--sudo", "--unit", "docker-compose-service@asterism", "0.1.3",
                         env: { "COMPOSE_FILE" => "/opt/wrap/asterism/docker-compose.yml" })
    assert st.success?, out
    assert_includes out, "+ sudo docker compose -f /opt/wrap/asterism/docker-compose.yml pull"
    assert_includes out, "+ sudo env CONSOLE_VERSION=0.1.3 docker compose -f /opt/wrap/asterism/docker-compose.yml run --rm --no-deps -T console bin/asterism backup"
    order = lines_matching(out, "+ sudo systemctl restart docker-compose-service@asterism", "up -d --remove-orphans")
    assert_equal order.sort, order
    assert_includes out, "--sudo --unit docker-compose-service@asterism -f /opt/wrap/asterism/docker-compose.yml 0.1.2 --restore"
    assert_unchanged
  end

  test "a wrapper by -f and no sudo: the flags reach every compose call" do
    out, st = run_script("--dry-run", "-f", "/opt/wrap/asterism/docker-compose.yml", "0.1.3")
    assert st.success?, out
    compose_lines = out.lines.grep(/\A\+ .*docker compose/)
    assert compose_lines.size >= 4
    assert(compose_lines.all? { _1.include?("-f /opt/wrap/asterism/docker-compose.yml") }, compose_lines.join)
  end

  test "refusals: no backup on either side, a bad version, local changes, a bad backup name" do
    File.write(@env, "CONSOLE_VERSION=0.1.1\n")
    out, st = run_script("--dry-run", "0.1.2")
    refute st.success?
    assert_match(/0\.1\.3 or later/, out)

    out, st = run_script("--dry-run", "latest")
    refute st.success?
    assert_match(/not a version/, out)

    File.write(@env, "CONSOLE_VERSION=0.1.2\n")
    out, st = run_script("--dry-run", "0.1.3", "--restore", "something.tgz")
    refute st.success?
    assert_match(/backup's file name/, out)

    File.write(File.join(@vps, "docker-compose.yml"), "changed\n", mode: "a")
    out, st = run_script("--dry-run", "0.1.3")
    refute st.success?
    assert_match(/local changes/, out)
  end

  test "--help prints the usage" do
    out, st = run_script("--help")
    assert st.success?
    assert_includes out, "--restore NAME"
  end
end
