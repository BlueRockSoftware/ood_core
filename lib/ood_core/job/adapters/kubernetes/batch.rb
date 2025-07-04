require "ood_core/refinements/hash_extensions"
require "json"
require "logger"
require "fileutils"

# Utility class for the Kubernetes adapter to interact
# with the Kuberenetes APIs.
class OodCore::Job::Adapters::Kubernetes::Batch

  require_relative "helper"
  require_relative "k8s_job_info"

  using OodCore::Refinements::HashExtensions

  class Error < StandardError; end
  class NotFoundError < StandardError; end

  LOG_FILE = "/tmp/ood-core.log"
  LOG_DIR = File.dirname(LOG_FILE)

  attr_reader :config_file, :bin, :cluster, :context, :mounts
  attr_reader :all_namespaces, :helper
  attr_reader :username_prefix, :namespace_prefix
  attr_reader :auto_supplemental_groups
  attr_reader :logger

  def initialize(options = {})
    options = options.to_h.symbolize_keys

    setup_logger

    @config_file = options.fetch(:config_file, self.class.default_config_file)
    @bin = options.fetch(:bin, '/usr/bin/kubectl')
    @cluster = options.fetch(:cluster, 'open-ondemand')
    @mounts = options.fetch(:mounts, []).map { |m| m.to_h.symbolize_keys }
    @all_namespaces = options.fetch(:all_namespaces, false)
    @username_prefix = options.fetch(:username_prefix, '')
    @namespace_prefix = options.fetch(:namespace_prefix, '')
    @auto_supplemental_groups = options.fetch(:auto_supplemental_groups, false)

    tmp_ctx = options.fetch(:context, nil)
    @context = tmp_ctx.nil? && oidc_auth?(options.fetch(:auth, {}).symbolize_keys) ? @cluster : tmp_ctx

    @helper = OodCore::Job::Adapters::Kubernetes::Helper.new

    log_initialization
  rescue => e
    # If we can't log to file, fall back to STDOUT for critical errors
    fallback_logger = Logger.new(STDOUT)
    fallback_logger.error("Failed to initialize Kubernetes Batch adapter: #{e.message}")
    fallback_logger.error(e.backtrace.join("\n"))
    raise
  end

  def resource_file(resource_type = 'pod')
    File.dirname(__FILE__) + "/templates/#{resource_type}.yml.erb"
  end

  def submit(script, after: [], afterok: [], afternotok: [], afterany: [])
    raise ArgumentError, 'Must specify the script' if script.nil?

    resource_yml, id = generate_id_yml(script)
    if !script.workdir.nil? && Dir.exist?(script.workdir)
      File.open(File.join(script.workdir, 'pod.yml'), 'w') { |f| f.write resource_yml }
    end
    call("#{formatted_ns_cmd} create -f -", stdin: resource_yml)

    id
  end

  def generate_id(name)
    # 2_821_109_907_456 = 36**8
    name.downcase.tr(' ', '-') + '-' + rand(2_821_109_907_456).to_s(36)
  end

  def info_all(attrs: nil)
    cmd = if @all_namespaces
            "#{base_cmd} -o json get pods --all-namespaces"
          else
            "#{namespaced_cmd} -o json get pods"
          end

    output = call(cmd)
    all_pods_to_info(output)
  end

  def info_where_owner(owner, attrs: nil)
    owner = Array.wrap(owner).map(&:to_s)

    # must at least have job_owner to filter by job_owner
    attrs = Array.wrap(attrs) | [:job_owner] unless attrs.nil?

    info_all(attrs: attrs).select { |info| owner.include? info.job_owner }
  end

  def info_all_each(attrs: nil)
    return to_enum(:info_all_each, attrs: attrs) unless block_given?

    info_all(attrs: attrs).each do |job|
      yield job
    end
  end

  def info_where_owner_each(owner, attrs: nil)
    return to_enum(:info_where_owner_each, owner, attrs: attrs) unless block_given?

    info_where_owner(owner, attrs: attrs).each do |job|
      yield job
    end
  end

  def info(id)
    pod_json = safe_call('get', 'pod', id)
    return OodCore::Job::Info.new(**{ id: id, status: 'completed' }) if pod_json.empty?

    service_json = safe_call('get', 'service', service_name(id))
    secret_json = safe_call('get', 'secret', secret_name(id))

    helper.info_from_json(pod_json: pod_json, service_json: service_json, secret_json: secret_json)
  end

  def status(id)
    info(id).status
  end

  def delete(id)
    safe_call("delete", "pod", id)
    safe_call("delete", "service", service_name(id))
    safe_call("delete", "secret", secret_name(id))
    safe_call("delete", "configmap", configmap_name(id))
  end

  class << self
    def default_config_file
      (ENV['KUBECONFIG'] || "#{Dir.home}/.kube/config")
    end

    def default_auth
      {
        type: 'managed'
      }.symbolize_keys
    end

    def default_server
      {
        endpoint: 'https://localhost:8080',
        cert_authority_file: nil
      }.symbolize_keys
    end

    def configure_kube!(config)
      k = self.new(config)
      # TODO: probably shouldn't be using send here
      k.send(:set_cluster, config.fetch(:server, default_server).to_h.symbolize_keys)
      k.send(:configure_auth, config.fetch(:auth, default_auth).to_h.symbolize_keys)
    end
  end

  private

  def setup_logger
    begin
      # Ensure log directory exists and is writable
      FileUtils.mkdir_p(LOG_DIR) unless Dir.exist?(LOG_DIR)
      FileUtils.touch(LOG_FILE) unless File.exist?(LOG_FILE)
      
      @logger = Logger.new(LOG_FILE, 'daily')
      @logger.level = Logger::INFO
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "[#{datetime}] #{severity} [#{self.class.name}]: #{msg}\n"
      end
    rescue => e
      # If we can't set up file logging, use STDOUT
      @logger = Logger.new(STDOUT)
      @logger.level = Logger::INFO
      @logger.warn("Could not set up file logging to #{LOG_FILE}: #{e.message}")
      @logger.warn("Falling back to STDOUT logging")
    end
  end

  def log_initialization
    @logger.info("Initialized Kubernetes Batch adapter with:")
    @logger.info("  config_file: #{@config_file}")
    @logger.info("  bin: #{@bin}")
    @logger.info("  cluster: #{@cluster}")
    @logger.info("  context: #{@context}")
    @logger.info("  namespace_prefix: #{@namespace_prefix}")
    @logger.info("  username_prefix: #{@username_prefix}")
    @logger.info("  all_namespaces: #{@all_namespaces}")
    @logger.info("  auto_supplemental_groups: #{@auto_supplemental_groups}")
    @logger.info("  mounts: #{@mounts.inspect}")
  rescue => e
    @logger.error("Failed to log initialization: #{e.message}")
  end

  def safe_call(verb, resource, id)
    begin
      case verb.to_s
      when "get"
        call_json_output('get', resource, id)
      when "delete"
        call("#{namespaced_cmd} delete #{resource} #{id} --wait=false")
      end
    rescue NotFoundError
      {}
    end
  end

  # helper to help format multi-line yaml data from the submit.yml into 
  # mutli-line yaml in the pod.yml.erb
  def config_data_lines(data)
    output = []
    first = true

    data.to_s.each_line do |line|
      output.append(first ? line : line.prepend("    "))
      first = false
    end

    output
  end

  def username
    @username ||= Etc.getlogin
  end

  def k8s_username
    "#{username_prefix}#{username}"
  end

  def user
    @user ||= Etc.getpwnam(username)
  end

  def home_dir
    user.dir
  end

  def run_as_user
    if @native_data && @native_data[:container] && @native_data[:container][:securityContext]
      @native_data[:container][:securityContext][:runAsUser]
    else
      user.uid
    end
  end

  def run_as_group
    if @native_data && @native_data[:container] && @native_data[:container][:securityContext]
      @native_data[:container][:securityContext][:runAsGroup]
    else
      user.gid
    end
  end

  def run_as_non_root
    if @native_data && @native_data[:container] && @native_data[:container][:securityContext]
      @native_data[:container][:securityContext][:runAsNonRoot]
    else
      true
    end
  end

  def fs_group
    if @native_data && @native_data[:container] && @native_data[:container][:securityContext]
      @native_data[:container][:securityContext][:fsGroup]
    else
      run_as_group
    end
  end

  def group
    Etc.getgrgid(run_as_group).name
  end

  def default_supplemental_groups
    OodSupport::User.new.groups.sort_by(&:id).map(&:id).reject { |id| id < 1000 }
  end

  def supplemental_groups(groups = [])
    sgroups = []
    if auto_supplemental_groups
      sgroups.concat(default_supplemental_groups)
    end
    sgroups.concat(groups.to_a)
    sgroups.uniq.sort
  end

  def default_env
    {
      USER: username,
      UID: run_as_user,
      HOME: home_dir,
      GROUP: group,
      GID: run_as_group,
      KUBECONFIG: '/dev/null',
    }
  end

  # helper to template resource yml you're going to submit and
  # create an id.
  def generate_id_yml(script)
    @logger.debug("Starting generate_id_yml with script: #{script.inspect}")
    
    @native_data = script.native
    @logger.debug("Native data: #{@native_data.inspect}")
    
    if @native_data.nil?
      @logger.error("script.native returned nil")
      raise Error, "Native data cannot be nil"
    end
    
    if @native_data[:container].nil?
      @logger.error("native_data[:container] is nil. Full native_data: #{@native_data.inspect}")
      raise Error, "Container configuration cannot be nil"
    end

    # Initialize container if it doesn't exist
    @native_data[:container] ||= {}
    @native_data[:container][:supplemental_groups] ||= []
    
    @logger.debug("Before supplemental_groups modification - container: #{@native_data[:container].inspect}")
    @native_data[:container][:supplemental_groups] = supplemental_groups(@native_data[:container][:supplemental_groups])
    @logger.debug("After supplemental_groups modification - container: #{@native_data[:container].inspect}")

    container = helper.container_from_native(@native_data[:container], default_env)
    @logger.debug("Created container from native data: #{container.inspect}")
    
    id = generate_id(container.name)
    @logger.debug("Generated ID: #{id}")
    
    configmap = helper.configmap_from_native(@native_data, id, script.content)
    @logger.debug("Created configmap: #{configmap.inspect}")
    
    init_containers = helper.init_ctrs_from_native(@native_data[:init_containers], container.env)
    @logger.debug("Created init containers: #{init_containers.inspect}")
    
    spec = OodCore::Job::Adapters::Kubernetes::Resources::PodSpec.new(container, init_containers: init_containers)
    @logger.debug("Created pod spec: #{spec.inspect}")
    
    all_mounts = @native_data[:mounts].nil? ? mounts : mounts + @native_data[:mounts]
    @logger.debug("Using mounts: #{all_mounts.inspect}")
    
    node_selector = @native_data[:node_selector].nil? ? {} : @native_data[:node_selector]
    @logger.debug("Using node selector: #{node_selector.inspect}")
    
    gpu_type = @native_data[:gpu_type].nil? ? "nvidia.com/gpu" : @native_data[:gpu_type]
    @logger.debug("Using GPU type: #{gpu_type}")

    template = ERB.new(File.read(resource_file), trim_mode: '-')
    @logger.debug("Created ERB template from #{resource_file}")

    [template.result(binding), id]
  rescue => e
    @logger.error("Error in generate_id_yml: #{e.message}")
    @logger.error("Backtrace: #{e.backtrace.join("\n")}")
    raise
  end

  # helper to call kubectl and get json data back.
  # verb, resrouce and id are the kubernetes parlance terms.
  # example: 'kubectl get pod my-pod-id' is verb=get, resource=pod
  # and  id=my-pod-id
  def call_json_output(verb, resource, id, stdin: nil)
    cmd = "#{formatted_ns_cmd} #{verb} #{resource} #{id}"

    data = call(cmd, stdin: stdin)
    data = data.empty? ? '{}' : data
    json_data = JSON.parse(data, symbolize_names: true)

    json_data
  end

  def service_name(id)
    helper.service_name(id)
  end

  def secret_name(id)
    helper.secret_name(id)
  end

  def configmap_name(id)
    helper.configmap_name(id)
  end

  def namespace
    "#{namespace_prefix}#{username.gsub(/[.@_]/, '-')}"
  end

  def formatted_ns_cmd
    "#{namespaced_cmd} -o json"
  end

  def namespaced_cmd
    "#{base_cmd} --namespace=#{namespace}"
  end

  def base_cmd
    base = "#{bin} --kubeconfig=#{config_file}"
    base << " --context=#{context}" if context?
    base
  end

  def all_pods_to_info(data)
    json_data = JSON.parse(data, symbolize_names: true)
    pods = json_data.dig(:items)

    info_array = []
    pods.each do |pod|
      info = pod_info_from_json(pod)
      info_array.push(info) if info
    end

    info_array
  rescue JSON::ParserError
    # 'no resources in <namespace>' throws parse error
    []
  end

  def pod_info_from_json(pod)
    hash = helper.pod_info_from_json(pod)
    OodCore::Job::Adapters::Kubernetes::K8sJobInfo.new(hash)
  end

  def configure_auth(auth)
    if managed_auth?(auth)
      return
    elsif gke_auth?(auth)
      set_gke_config(auth)
    elsif oidc_auth?(auth)
      set_context if context?
    end
  end

  def context?
    !@context.nil?
  end

  def gke_auth?(auth = {})
    auth.fetch(:type, nil) == 'gke'
  end

  def oidc_auth?(auth = {})
    auth.fetch(:type, nil) == 'oidc'
  end

  def managed_auth?(auth = {})
    type = auth.fetch(:type, nil)
    if type.nil?
      true # maybe should be false?
    else
      type.to_s == 'managed'
    end
  end

  def set_gke_config(auth)
    cred_file = auth.fetch(:svc_acct_file)

    cmd = "gcloud auth activate-service-account --key-file=#{cred_file}"
    call(cmd)

    set_gke_credentials(auth)
  end

  def set_gke_credentials(auth)

    zone = auth.fetch(:zone, nil)
    region = auth.fetch(:region, nil)

    locale = ''
    locale = "--zone=#{zone}" unless zone.nil?
    locale = "--region=#{region}" unless region.nil?

    # gke cluster name can probably can differ from what ood calls the cluster
    cmd = "gcloud container clusters get-credentials #{locale} #{cluster}"
    env = { 'KUBECONFIG' => config_file }
    call(cmd, env: env)
  end

  def set_context
    # can't really use base_cmd, bc it may use --context flag
    cmd = "#{bin} --kubeconfig=#{config_file} config set-context #{context}"
    cmd << " --cluster=#{cluster} --namespace=#{namespace}"
    cmd << " --user=#{k8s_username}"

    call(cmd)
  end

  def set_cluster(config)
    server = config.fetch(:endpoint)
    cert = config.fetch(:cert_authority_file, nil)

    # shouldn't use context here either
    cmd = "#{bin} --kubeconfig=#{config_file} config set-cluster #{cluster}"
    cmd << " --server=#{server}"
    cmd << " --certificate-authority=#{cert}" unless cert.nil?

    call(cmd)
  end

  def call(cmd = '', env: {}, stdin: nil)
    @logger.debug("Executing command: #{cmd}")
    o, e, s = Open3.capture3(env, cmd, stdin_data: stdin.to_s)
    if s.success?
      @logger.debug("Command succeeded")
      o
    else
      @logger.error("Command failed: #{e}")
      interpret_and_raise(e)
    end
  rescue => e
    @logger.error("Exception during command execution: #{e.message}")
    raise
  end

  def interpret_and_raise(stderr)
    if /^Error from server \(NotFound\):/.match(stderr)
      @logger.warn("Resource not found: #{stderr}")
      raise NotFoundError, stderr
    else
      @logger.error("Error from server: #{stderr}")
      raise(Error, stderr)
    end
  end
end
