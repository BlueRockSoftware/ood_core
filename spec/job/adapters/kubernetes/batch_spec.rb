require "ood_core/job/adapters/kubernetes"
require "ood_core/job/adapters/kubernetes/batch"
require 'tmpdir'
require 'yaml'

describe OodCore::Job::Adapters::Kubernetes::Batch do

  Batch = OodCore::Job::Adapters::Kubernetes::Batch
  Helper = OodCore::Job::Adapters::Kubernetes::Helper
  K8sJobInfo = OodCore::Job::Adapters::Kubernetes::K8sJobInfo
  User = Struct.new(:dir, :uid, :gid, keyword_init: true)

  let(:helper) {
    helper = Helper.new
    allow(helper).to receive(:get_host).with(nil).and_return(nil)
    allow(helper).to receive(:get_host).with('10.20.0.40').and_return('10.20.0.40')
    allow(helper).to receive(:get_host).with('192.148.247.227').and_return('192.148.247.227')
    helper
  }

  let(:pod_yml_from_all_configs) { File.read('spec/fixtures/output/k8s/pod_yml_from_all_configs.yml') }
  let(:pod_yml_from_defaults) { File.read('spec/fixtures/output/k8s/pod_yml_from_defaults.yml') }
  let(:pod_yml_extra_groups) { File.read('spec/fixtures/output/k8s/pod_yml_extra_groups.yml') }
  let(:pod_yml_no_init_container) { File.read('spec/fixtures/output/k8s/pod_yml_no_init_container.yml') }
  let(:pod_yml_no_mounts) { File.read('spec/fixtures/output/k8s/pod_yml_no_mounts.yml') }
  let(:pod_yml_subpath_configmap) { File.read('spec/fixtures/output/k8s/pod_yml_subpath_configmap.yml') }
  let(:pod_yml_no_mounts_no_configmaps) { File.read('spec/fixtures/output/k8s/pod_yml_no_mounts_no_configmaps.yml') }
  let(:pod_yml_no_configmaps) { File.read('spec/fixtures/output/k8s/pod_yml_no_configmaps.yml') }
  let(:several_pods) { File.read('spec/fixtures/output/k8s/several_pods.json') }
  let(:single_running_pod) { File.read('spec/fixtures/output/k8s/single_running_pod.json') }
  let(:single_error_pod) { File.read('spec/fixtures/output/k8s/single_error_pod.json') }
  let(:single_completed_pod) { File.read('spec/fixtures/output/k8s/single_completed_pod.json') }
  let(:single_queued_pod) { File.read('spec/fixtures/output/k8s/single_queued_pod.json') }
  let(:single_unscheduleable_pod) { File.read('spec/fixtures/output/k8s/single_unscheduleable_pod.json') }
  let(:single_service) { File.read('spec/fixtures/output/k8s/single_service.json') }
  let(:single_secret) { File.read('spec/fixtures/output/k8s/single_secret.json') }
  let(:single_secret) { File.read('spec/fixtures/output/k8s/single_secret.json') }
  let(:ns_prefixed_pod) { File.read('spec/fixtures/output/k8s/ns_prefixed_pod.json') }

  let(:now) { DateTime.parse("2020-04-28 20:18:30 +0000") }
  let(:past) { DateTime.parse("2020-04-18 13:01:56 +0000") }

  let(:success) { double("success?" => true) }
  let(:failure) { double("success?" => false) }

  let(:script_content) do
    content = <<-EOS
#!/bin/bash
foo
EOS
    content.strip
  end

  let(:mounts) {
    [
      {
        type: 'host',
        name: 'home-dir',
        host_type: 'Directory',
        destination_path: '/home',
        path: '/users'
      },
      {
        type: 'nfs',
        name: 'nfs-dir',
        host: 'some.nfs.host',
        destination_path: '/fs',
        path: '/fs'
      }
    ]
  }

  let(:config) {
    {
      config_file: '~/kube.config',
      bin: '/usr/bin/wontwork',
      cluster: 'test-cluster',
      context: 'ood-test-cluster',
      mounts: mounts,
      all_namespaces: true,
      namespace_prefix: 'user-',
      username_prefix: 'dev-',
      server: {
        endpoint: 'https://some.k8s.host',
        cert_authority_file: '/etc/some.cert'
      },
      auth: {
        type: 'oidc'
      },
      auto_supplemental_groups: true
    }
  }

  before(:each) do
    @basic_batch = described_class.new({})
    allow(@basic_batch).to receive(:username).and_return('testuser')
    allow(@basic_batch).to receive(:helper).and_return(helper)
  end

  let(:configured_batch){
    batch = described_class.new(config)
    allow(batch).to receive(:username).and_return('testuser')
    allow(batch).to receive(:helper).and_return(helper)

    batch
  }

  let(:ten_twenty_host_connection){{ host: "10.20.0.40" }}
  let(:nil_connection){{ host: nil}}
  let(:full_connection){{
    host: "10.20.0.40",
    port: 30689,
    password:  "ekmfxbOgNUlmLy4m"
  }}

  let(:several_pods_info){
    [
      K8sJobInfo.new({
        id: "bash",
        status:  "completed",
        job_name: "bash",
        job_owner: "johrstrom",
        dispatch_time: 1588023136,
        submission_time: 1588023135,
        wallclock_time: 300,
        ood_connection_info: ten_twenty_host_connection
      }),
      K8sJobInfo.new({
        id: "bash-ssd",
        status:  "queued_held",
        job_name: "bash-ssd",
        job_owner: "johrstrom",
        dispatch_time: nil,
        submission_time: 1588023155,
        wallclock_time: nil,
        ood_connection_info: nil_connection
      }),
      K8sJobInfo.new({
        id: 'jupyter-3pjruck9',
        status: 'suspended',
        job_name: "jupyter",
        job_owner: "johrstrom",
        dispatch_time: nil,
        submission_time: 1588106996,
        wallclock_time: nil,
        ood_connection_info: ten_twenty_host_connection
      }),
      K8sJobInfo.new({
        id: 'jupyter-q323v88u',
        status: 'running',
        job_name: "jupyter",
        job_owner: "johrstrom",
        dispatch_time: 1588089059,
        submission_time: 1588089047,
        wallclock_time: 16051,
        ood_connection_info: ten_twenty_host_connection
      })
    ]
  }

  let(:single_running_pod_info) {
    K8sJobInfo.new({
      id: "jupyter-bmurb8sa",
      status: OodCore::Job::Status.new(state: "running"),
      job_name: "jupyter",
      job_owner: "johrstrom",
      dispatch_time: 1587060509,
      submission_time: 1587060496,
      wallclock_time: 154407,
      ood_connection_info: ten_twenty_host_connection,
      procs: 1
    })
  }

  let(:single_running_pod_with_native_info) {
    K8sJobInfo.new({
      id: "jupyter-bmurb8sa",
      status: OodCore::Job::Status.new(state: "running"),
      job_name: "jupyter",
      job_owner: "johrstrom",
      dispatch_time: 1587060509,
      submission_time: 1587060496,
      wallclock_time: 154407,
      ood_connection_info: full_connection,
      procs: 1
    })
  }

  let(:single_error_pod_info) {
    K8sJobInfo.new({
      id: "jupyter-h6kw06ve",
      status: OodCore::Job::Status.new(state: "suspended"),
      job_name: "jupyter",
      job_owner: "johrstrom",
      dispatch_time: nil,
      submission_time: 1587069112,
      wallclock_time: nil,
      ood_connection_info: ten_twenty_host_connection
    })
  }

  let(:single_completed_pod_info) {
    K8sJobInfo.new({
      id: "bash",
      status: OodCore::Job::Status.new(state: "completed"),
      job_name: "bash",
      job_owner: "johrstrom",
      dispatch_time: 1587506633,
      submission_time: 1587506632,
      wallclock_time: 300,
      ood_connection_info: ten_twenty_host_connection
    })
  }


  let(:single_queued_pod_info) {
    K8sJobInfo.new({
      id: "jupyter-28wixphq",
      status: OodCore::Job::Status.new(state: "queued"),
      job_name: "jupyter",
      job_owner: "johrstrom",
      dispatch_time: nil,
      submission_time: 1587580037,
      wallclock_time: nil,
      ood_connection_info: ten_twenty_host_connection
    })
  }

  let(:single_unscheduleable_pod_info) {
    K8sJobInfo.new({
      id: "bash",
      status: OodCore::Job::Status.new(state: "queued_held"),
      job_name: "bash",
      job_owner: "johrstrom",
      dispatch_time: nil,
      submission_time: 1587580582,
      wallclock_time: nil,
      ood_connection_info: nil_connection,
      procs: 1
    })
  }


  describe "#initialize" do
    it "configures correctly when given items" do
      expect(configured_batch.config_file).to eq('~/kube.config')
      expect(configured_batch.bin).to eq('/usr/bin/wontwork')
      expect(configured_batch.mounts).to eq(mounts)
      expect(configured_batch.namespace_prefix).to eq('user-')
    end

    it "configures correctly configures defaults" do
      expect(@basic_batch.config_file).to eq("#{ENV['HOME']}/.kube/config")
      expect(@basic_batch.bin).to eq('/usr/bin/kubectl')
      expect(@basic_batch.mounts).to eq([])
      expect(@basic_batch.context).to eq(nil)
    end

    it "does not throw an error when it can't configure" do
      allow(Open3).to receive(:capture3).and_return(['', '', failure])

      expect { described_class.new }.not_to raise_error
      expect { described_class.new(config) }.not_to raise_error
      expect { described_class.new({}) }.not_to raise_error
    end

    it "defaults context to cluster for oidc auth" do
      cfg = {
        'cluster' => 'some-cluster',
        'auth' => {
          'type' => 'oidc'
        }
      }

      k = described_class.new(cfg)
      expect(k.context).to eq(k.cluster)
      expect(k.context).to eq('some-cluster')
      expect(k.cluster).to eq('some-cluster')
      expect(k.send(:context?)).to eq(true)
    end
  end

  describe "#submit" do
    def build_script(opts = {})
      OodCore::Job::Script.new(
        **{
          content: nil
        }.merge(opts)
      )
    end

    let(:script) do
      OodCore::Job::Script.new(
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.7',
            command: 'bash',
            port: 8080,
            env: {
              HOME: '/home',
              PATH: '/usr/bin'
            },
            memory: '1Gi',
            cpu: '1',
            working_dir: '/home',
            restart_policy: 'Never',
            image_pull_policy: 'IfNotPresent',
            securityContext: {
              runAsUser: 1000,
              runAsGroup: 1000,
              runAsNonRoot: true
            }
          },
          configmap: {
            files: [
              {
                filename: 'test1.conf',
                data: "test1 data\n",
                mount_path: '/etc/test/',
                sub_path: 'test1.conf'
              },
              {
                filename: 'test2.conf',
                data: "test2 data\n",
                mount_path: '/etc/test/',
                sub_path: 'test2.conf'
              }
            ]
          }
        }
      )
    end

    it "submits with correct yml file given all config options" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        gpus_per_node: 1,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            image_pull_secret: 'docker-registry-secret',
            image_pull_policy: 'Always',
            command: 'rake spec',
            port: 8080,
            startup_probe: { failure_threshold: 10 },
            env: {
              HOME: '/my/home',
              PATH: '/usr/bin:/usr/local/bin',
              KUBECONFIG: '/my/home/.kube/config',
            },
            labels: {
              cluster: 'foo',
            },
            memory_limit: '4Gi',
            memory_request: '2Gi',
            cpu_limit: '1',
            cpu_request: '0.5',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            image_pull_policy: 'Always',
            command: '/bin/ls -lrt .'
          ],
          configmap: {
            files: [{
              filename: 'config.file',
              data: "a = b\nc = d\n  indentation = keepthis",
              mount_path: '/ood',
              init_mount_path: '/ood'
            }],
          },
          mounts: [
            type: 'host',
            name: 'ess',
            host_type: 'Directory',
            destination_path: '/fs/ess',
            path: '/fs/ess'
          ],
          node_selector: {
            cluster: 'test',
          }
        }
      )

      allow(configured_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(configured_batch).to receive(:username).and_return('testuser')
      allow(configured_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(configured_batch).to receive(:group).and_return('testgroup')
      allow(configured_batch).to receive(:default_supplemental_groups).and_return([1000,1001])

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = configured_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_from_all_configs.to_s)

      # make sure template get's passed into command correctly
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/wontwork --kubeconfig=~/kube.config --context=ood-test-cluster " \
        "--namespace=user-testuser -o json create -f -",
        stdin_data: pod_yml_from_all_configs.to_s
      ).and_return(['', '', success])

      configured_batch.submit(script)
    end

    it "submits with correct yml file given default options" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              'HOME' => '/my/home',
              'PATH' => '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            command: '/bin/ls -lrt .'
          ],
          configmap: {
            files: [{
              filename: 'config.file',
              data: "a = b\nc = d\n  indentation = keepthis",
              mount_path: '/ood'
            }],
          },
          mounts: [
            type: 'host',
            name: 'ess',
            host_type: 'Directory',
            destination_path: '/fs/ess',
            path: '/fs/ess'
          ]
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_from_defaults.to_s)

      # make sure template get's passed into command correctly
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_from_defaults.to_s
      ).and_return(['', '', success])

      @basic_batch.submit(script)
    end

    it "submits with correct yml file given extra supplemental groups" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              'HOME' => '/my/home',
              'PATH' => '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always',
            supplemental_groups: [1002],
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            command: '/bin/ls -lrt .'
          ],
          configmap: {
            files: [{
              filename: 'config.file',
              data: "a = b\nc = d\n  indentation = keepthis",
              mount_path: '/ood'
            }],
          },
          mounts: [
            type: 'host',
            name: 'ess',
            host_type: 'Directory',
            destination_path: '/fs/ess',
            path: '/fs/ess'
          ]
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')
      allow(@basic_batch).to receive(:auto_supplemental_groups).and_return(true)
      allow(@basic_batch).to receive(:default_supplemental_groups).and_return([1000,1001])

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_extra_groups.to_s)

      # make sure template get's passed into command correctly
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_extra_groups.to_s
      ).and_return(['', '', success])

      @basic_batch.submit(script)
    end

    it "submits with correct yml file with no mounts" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              PATH: '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            command: '/bin/ls -lrt .'
          ],
          configmap: {
            files: [{
              filename: 'config.file',
              data: "a = b\nc = d\n  indentation = keepthis",
              mount_path: '/ood'
            }],
          },
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_no_mounts.to_s)

      # make sure template get's passed into command correctly
      `true`
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_no_mounts.to_s
      ).and_return(['', '', $?])

      @basic_batch.submit(script)
    end

    it "submits with correct yml file given no init containers" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              'HOME' => '/my/home',
              'PATH' => '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          configmap: {
            files: [{
              filename: 'config.file',
              data: "a = b\nc = d\n  indentation = keepthis",
              mount_path: '/ood'
            }],
          },
          mounts: [
            type: 'host',
            name: 'ess',
            host_type: 'Directory',
            destination_path: '/fs/ess',
            path: '/fs/ess'
          ]
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_no_init_container.to_s)

      # make sure template get's passed into command correctly
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_no_init_container.to_s
      ).and_return(['', '', success])

      @basic_batch.submit(script)
    end

    it "submits with correct yml file with subpath mounts for configmap" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              HOME: '/my/home',
              PATH: '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            command: '/bin/ls -lrt .'
          ],
          configmap: {
            files: [
              {
                filename: 'config.file',
                data: "a = b\nc = d\n  indentation = keepthis",
                mount_path: '/ood',
                init_mount_path: '/ood'
              },
              {
                filename: 'passwd',
                mount_path: '/etc/passwd',
                sub_path: 'passwd',
                init_mount_path: '/passwd'
              },
              {
                filename: 'group',
                mount_path: '/etc/group',
                sub_path: 'group',
              }
            ],
          },
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_subpath_configmap.to_s)

      # make sure template get's passed into command correctly
      `true`
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_subpath_configmap.to_s
      ).and_return(['', '', $?])

      @basic_batch.submit(script)
    end

    it "submits with correct yml file with no mounts no configmap mounts" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              PATH: '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            command: '/bin/ls -lrt .'
          ],
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_no_mounts_no_configmaps.to_s)

      # make sure template get's passed into command correctly
      `true`
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_no_mounts_no_configmaps.to_s
      ).and_return(['', '', $?])

      @basic_batch.submit(script)
    end

    it "submits with correct yml file with no configmap mounts" do
      script = build_script(
        accounting_id: 'test',
        content: script_content,
        native: {
          container: {
            name: 'rspec-test',
            image: 'ruby:2.5',
            command: 'rake spec',
            port: 8080,
            env: {
              PATH: '/usr/bin:/usr/local/bin'
            },
            memory: '6Gi',
            cpu: '4',
            working_dir: '/my/home',
            restart_policy: 'Always'
          },
          init_containers: [
            name: 'init-1',
            image: 'busybox:latest',
            command: '/bin/ls -lrt .'
          ],
          mounts: [
            type: 'host',
            name: 'ess',
            host_type: 'Directory',
            destination_path: '/fs/ess',
            path: '/fs/ess'
          ]
        }
      )

      allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
      allow(@basic_batch).to receive(:username).and_return('testuser')
      allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
      allow(@basic_batch).to receive(:group).and_return('testgroup')

      # make sure it get's templated right, also helpful in debugging bc
      # it'll show a better diff than the test below.
      template, = @basic_batch.send(:generate_id_yml, script)
      expect(template.to_s).to eql(pod_yml_no_configmaps.to_s)

      # make sure template get's passed into command correctly
      `true`
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json create -f -",
        stdin_data: pod_yml_no_configmaps.to_s
      ).and_return(['', '', $?])

      @basic_batch.submit(script)
    end

    it "saves pod YAML" do
      Dir.mktmpdir do |tmp|
        pod_yml_path = File.join(tmp, "pod.yml")
        script = build_script(
          accounting_id: 'test',
          workdir: tmp,
          content: script_content,
          native: {
            container: {
              name: 'rspec-test',
              image: 'ruby:2.5',
              command: 'rake spec',
              port: 8080,
              env: {
                'HOME' => '/my/home',
                'PATH' => '/usr/bin:/usr/local/bin'
              },
              memory: '6Gi',
              cpu: '4',
              working_dir: '/my/home',
              restart_policy: 'Always'
            },
            init_containers: [
              name: 'init-1',
              image: 'busybox:latest',
              command: '/bin/ls -lrt .'
            ],
            configmap: {
              files: [{
                filename: 'config.file',
                data: "a = b\nc = d\n  indentation = keepthis",
                mount_path: '/ood'
              }],
            },
            mounts: [
              type: 'host',
              name: 'ess',
              host_type: 'Directory',
              destination_path: '/fs/ess',
              path: '/fs/ess'
            ]
          }
        )

        allow(@basic_batch).to receive(:generate_id).with('rspec-test').and_return('rspec-test-123')
        allow(@basic_batch).to receive(:username).and_return('testuser')
        allow(@basic_batch).to receive(:user).and_return(User.new(dir: '/home/testuser', uid: 1001, gid: 1002))
        allow(@basic_batch).to receive(:group).and_return('testgroup')

        template, = @basic_batch.send(:generate_id_yml, script)

        # make sure template get's passed into command correctly
        allow(Open3).to receive(:capture3).with(
          {},
          "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
          "--namespace=testuser -o json create -f -",
          stdin_data: pod_yml_from_defaults.to_s
        ).and_return(['', '', success])

        @basic_batch.submit(script)
        expect(File.exist?(pod_yml_path)).to be true
        #expect(template.to_s).to eql(File.read(pod_yml_path))
      end
    end

    it 'creates unique volume names for each configmap file' do
      allow(batch).to receive(:call).and_return('{}')
      allow(batch).to receive(:generate_id).and_return('test-id')
      
      # Capture the generated YAML
      yaml_content = nil
      allow(File).to receive(:open).with(any_args) do |path, mode, &block|
        if path.end_with?('pod.yml')
          yaml_content = block.call(File.new('/dev/null'))
        end
      end
      
      batch.submit(script)
      
      # Parse the YAML and verify volume names
      yaml = YAML.load(yaml_content)
      volume_mounts = yaml['spec']['containers'][0]['volumeMounts']
      volumes = yaml['spec']['volumes']
      
      # Verify we have two volume mounts with different names
      expect(volume_mounts.length).to eq(2)
      expect(volume_mounts[0]['name']).not_to eq(volume_mounts[1]['name'])
      
      # Verify the volume names match between mounts and volumes
      volume_names = volumes.map { |v| v['name'] }
      mount_names = volume_mounts.map { |m| m['name'] }
      expect(volume_names).to match_array(mount_names)
      
      # Verify the volume names are sanitized
      volume_names.each do |name|
        expect(name).to match(/^[a-z0-9][a-z0-9\-\._]*[a-z0-9]$/)
        expect(name.length).to be <= 63
      end
    end
  end

  describe "#delete" do
    it "deletes all the resources with the right commands" do

      # be sure to delete the pod and all the extra resources
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete pod test-pod-123 --wait=false",
        stdin_data: ""
      ).and_return(['', '', success])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete secret test-pod-123-secret --wait=false",
        stdin_data: ""
      ).and_return(['', '', success])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete service test-pod-123-service --wait=false",
        stdin_data: ""
      ).and_return(['', '', success])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete configmap test-pod-123-configmap --wait=false",
        stdin_data: ""
      ).and_return(['', '', success])

      @basic_batch.delete('test-pod-123')
    end

    it "safely tries to delete resources that don't exist" do

      id = "rspec-test"

      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete pod #{id} --wait=false",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): pods \"#{id}\" not found", failure])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete secret #{id}-secret --wait=false",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): secrets \"#{id}-secret\" not found", failure])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete service #{id}-service --wait=false",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): services \"#{id}-service\" not found", failure])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser delete configmap #{id}-configmap --wait=false",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): configmaps \"#{id}-configmap\" not found", failure])

      @basic_batch.delete(id)
    end
  end

  describe "#info_all" do
    it "correctly handles no data" do
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get pods",
        stdin_data: ""
      ).and_return(['No resources found in testuser namespace.', '', success])

      expect(@basic_batch.info_all).to eq([])
    end

    errmsg = 'Error from server (Forbidden): pods is forbidden: User "testuser" cannot list resource "pods" in API group "" at the cluster scope'
    it "throws error up the stack with --all-namespaces" do
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/wontwork --kubeconfig=~/kube.config --context=ood-test-cluster -o json get pods --all-namespaces",
        stdin_data: ""
      ).and_return(['', errmsg, failure])

      expect { configured_batch.info_all }.to raise_error(Batch::Error, errmsg)
    end

    it "correctly handles good data" do
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get pods",
        stdin_data: ""
      ).and_return([several_pods, '', success])

      allow(DateTime).to receive(:now).and_return(now)

      expect(@basic_batch.info_all).to eq(several_pods_info)
    end
  end

  describe "#info" do
    def info_batch(id, file)
      batch = described_class.new({})
      allow(batch).to receive(:username).and_return('testuser')
      allow(batch).to receive(:helper).and_return(helper)
      allow(DateTime).to receive(:now).and_return(past)

      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get pod #{id}",
        stdin_data: ""
      ).and_return([file, '', success])

      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get service #{id}-service",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): services \"#{id}-service\" not found", failure])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get secret #{id}-secret",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): secret \"#{id}-secret\" not found", failure])

      batch
    end

    def info_batch_full(id)
      batch = described_class.new({})
      allow(batch).to receive(:username).and_return('testuser')
      allow(DateTime).to receive(:now).and_return(past)

      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get pod #{id}",
        stdin_data: ""
      ).and_return([single_running_pod, '', success])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get service #{id}-service",
        stdin_data: ""
      ).and_return([single_service, '', success])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get secret #{id}-secret",
        stdin_data: ""
      ).and_return([single_secret, '', success])

      batch
    end

    def not_found_batch(id)
      batch = described_class.new({})
      allow(batch).to receive(:username).and_return('testuser')
      allow(batch).to receive(:helper).and_return(helper)
      allow(DateTime).to receive(:now).and_return(past)

      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get pod #{id}",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): pod \"#{id}\" not found", failure])

      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get service #{id}-service",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): services \"#{id}-service\" not found", failure])
      allow(Open3).to receive(:capture3).with(
        {},
        "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config " \
        "--namespace=testuser -o json get secret #{id}-secret",
        stdin_data: ""
      ).and_return(['', "Error from server (NotFound): secret \"#{id}-secret\" not found", failure])

      batch
    end

    it "correctly returns a running pod" do
      batch = info_batch('jupyter-bmurb8sa', single_running_pod)
      info = batch.info('jupyter-bmurb8sa')
      expect(info).to eq(single_running_pod_info)
      expect(info.ood_connection_info).to eq(ten_twenty_host_connection)
    end

    it "correctly returns a errored pod" do
      batch = info_batch('jupyter-h6kw06ve', single_error_pod)
      info = batch.info('jupyter-h6kw06ve')
      expect(info).to eq(single_error_pod_info)
      expect(info.ood_connection_info).to eq(ten_twenty_host_connection)
    end

    it "correctly returns a completed pod" do
      batch = info_batch('bash', single_completed_pod)
      info = batch.info('bash')
      expect(info).to eq(single_completed_pod_info)
      expect(info.ood_connection_info).to eq(ten_twenty_host_connection)
    end

    it "correctly returns a queued pod" do
      batch = info_batch('jupyter-28wixphq', single_queued_pod)
      info = batch.info('jupyter-28wixphq')
      expect(info).to eq(single_queued_pod_info)
      expect(info.ood_connection_info).to eq(ten_twenty_host_connection)
    end

    it "correctly returns a unscheduleable pod" do
      batch = info_batch('bash', single_unscheduleable_pod)
      info = batch.info('bash')
      expect(info).to eq(single_unscheduleable_pod_info)
      expect(info.ood_connection_info).to eq(nil_connection)
    end

    it "correctly returns native info from service and secret" do
      batch = info_batch_full("jupyter-bmurb8sa")
      info = batch.info("jupyter-bmurb8sa")
      expect(info).to eq(single_running_pod_with_native_info)
      expect(info.ood_connection_info).to eq(full_connection)
    end

    it "handles not finding the pod" do
      id = "jupyter-3o4n6z3e"
      batch = not_found_batch(id)
      completed_info = OodCore::Job::Info.new(**{ id: id, status: 'completed' })
      expect(batch.info(id)).to eq(completed_info)
    end
  end

  describe '#configure_kube!' do
    it 'generates correct default commands' do
      expected_cmd = "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config config set-cluster open-ondemand --server=https://localhost:8080"
      expect_any_instance_of(Batch).to receive(:call).with(expected_cmd)
      Batch.configure_kube!({})
    end

    it 'generates correct default auth commands' do
      expected_cmd = "/usr/bin/kubectl --kubeconfig=#{ENV['HOME']}/.kube/config config set-cluster open-ondemand --server=https://localhost:8080"
      expect_any_instance_of(Batch).to receive(:call).with(expected_cmd)
      Batch.configure_kube!({ :auth => Batch.default_auth })
    end

    it 'generates sets oidc context' do
      set_cluster = "/usr/bin/wontwork --kubeconfig=~/kube.config config set-cluster test-cluster " \
        "--server=https://some.k8s.host --certificate-authority=/etc/some.cert"
      set_context = "/usr/bin/wontwork --kubeconfig=~/kube.config config set-context ood-test-cluster " \
        "--cluster=test-cluster --namespace=user-jessie --user=dev-jessie"

      expect_any_instance_of(Batch).to receive(:call).with(set_cluster)
      expect_any_instance_of(Batch).to receive(:username).and_return('jessie')
      expect_any_instance_of(Batch).to receive(:username).and_return('jessie')
      expect_any_instance_of(Batch).to receive(:call).with(set_context)
      Batch.configure_kube!(config)
    end

    it 'generates sets oidc context with default context' do
      set_cluster = "/usr/bin/wontwork --kubeconfig=~/kube.config config set-cluster test-cluster " \
        "--server=https://some.k8s.host --certificate-authority=/etc/some.cert"
      set_context = "/usr/bin/wontwork --kubeconfig=~/kube.config config set-context test-cluster " \
        "--cluster=test-cluster --namespace=user-jessie --user=dev-jessie"

      expect_any_instance_of(Batch).to receive(:call).with(set_cluster)
      expect_any_instance_of(Batch).to receive(:username).and_return('jessie')
      expect_any_instance_of(Batch).to receive(:username).and_return('jessie')
      expect_any_instance_of(Batch).to receive(:call).with(set_context)

      # let's make sure --context=#{cluster}
      cfg = config.tap { |h| h.delete(:context) }
      Batch.configure_kube!(cfg)
    end

    it 'runs the correct gke commands' do
      cfg = {
        :auth => {
          :type => 'gke',
          :region => 'ohio',
          :svc_acct_file => '~/.gke/acct.key',
        },
        :cluster => 'gke-cluster-oakley',
        :config_file => '~/.gke/oakley.config',
      }

      set_cluster = "/usr/bin/kubectl --kubeconfig=~/.gke/oakley.config config set-cluster gke-cluster-oakley " \
        "--server=https://localhost:8080"
      auth_activate = "gcloud auth activate-service-account --key-file=~/.gke/acct.key"
      ctr_cluster = "gcloud container clusters get-credentials --region=ohio gke-cluster-oakley"
      env = env = { 'KUBECONFIG' => '~/.gke/oakley.config' }

      expect_any_instance_of(Batch).to receive(:call).with(set_cluster)
      expect_any_instance_of(Batch).to receive(:call).with(auth_activate)
      expect_any_instance_of(Batch).to receive(:call).with(ctr_cluster, env: env)
      Batch.configure_kube!(cfg)
    end

    # same as the test above, only using --zone instead of --region
    it 'zone works in gke' do
      cfg = {
        :auth => {
          :type => 'gke',
          :zone => 'ohio',
          :svc_acct_file => '~/.gke/acct.key',
        },
        :cluster => 'gke-cluster-oakley',
        :config_file => '~/.gke/oakley.config',
      }

      set_cluster = "/usr/bin/kubectl --kubeconfig=~/.gke/oakley.config config set-cluster gke-cluster-oakley " \
        "--server=https://localhost:8080"
      auth_activate = "gcloud auth activate-service-account --key-file=~/.gke/acct.key"
      ctr_cluster = "gcloud container clusters get-credentials --zone=ohio gke-cluster-oakley"
      env = env = { 'KUBECONFIG' => '~/.gke/oakley.config' }

      expect_any_instance_of(Batch).to receive(:call).with(set_cluster)
      expect_any_instance_of(Batch).to receive(:call).with(auth_activate)
      expect_any_instance_of(Batch).to receive(:call).with(ctr_cluster, env: env)
      Batch.configure_kube!(cfg)
    end
  end
end
