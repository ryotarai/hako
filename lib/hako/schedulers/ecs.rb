# frozen_string_literal: true
require 'aws-sdk'
require 'hako'
require 'hako/scheduler'
require 'hako/schedulers/ecs_definition_comparator'
require 'hako/schedulers/ecs_elb'

module Hako
  module Schedulers
    class Ecs < Scheduler
      DEFAULT_CLUSTER = 'default'
      DEFAULT_FRONT_PORT = 10000

      def initialize(app_id, options, force:, dry_run:)
        @app_id = app_id
        @cluster = options.fetch('cluster', DEFAULT_CLUSTER)
        @desired_count = options.fetch('desired_count') { validation_error!('desired_count must be set') }
        region = options.fetch('region') { validation_error!('region must be set') }
        @role = options.fetch('role', nil)
        @ecs = Aws::ECS::Client.new(region: region)
        @elb = EcsElb.new(app_id, Aws::ElasticLoadBalancing::Client.new(region: region), options.fetch('elb', nil))
        @ec2 = Aws::EC2::Client.new(region: region)
        @force = force
        @dry_run = dry_run
      end

      def deploy(containers)
        app = containers.fetch('app')
        front = containers.fetch('front')
        front_port = determine_front_port
        definitions = create_definitions(containers, front_port)

        if @dry_run
          definitions.each do |d|
            Hako.logger.info "Add container #{d}"
          end
        else
          task_definition = register_task_definition(definitions)
          if task_definition == :noop
            Hako.logger.info "Task definition isn't changed"
            task_definition = @ecs.describe_task_definition(task_definition: @app_id).task_definition
          else
            Hako.logger.info "Registered task definition: #{task_definition.task_definition_arn}"
            upload_front_config(@app_id, front, app.port)
            Hako.logger.debug "Uploaded front configuration to s3://#{front.s3.bucket}/#{front.s3.key(@app_id)}"
          end
          service = create_or_update_service(task_definition.task_definition_arn, front_port)
          if service == :noop
            Hako.logger.info "Service isn't changed"
          else
            Hako.logger.info "Updated service: #{service.service_arn}"
            wait_for_ready(service)
          end
          Hako.logger.info 'Deployment completed'
        end
      end

      def oneshot(containers, commands)
        definitions = create_definitions(containers, -1)
        definitions.each do |definition|
          definition.delete(:essential)
        end
        task_definition = register_task_definition_for_oneshot(definitions)
        if task_definition == :noop
          Hako.logger.info "Task definition isn't changed"
          task_definition = @ecs.describe_task_definition(task_definition: "#{@app_id}-oneshot").task_definition
        else
          Hako.logger.info "Registered task definition: #{task_definition.task_definition_arn}"
        end
        task = run_task(task_definition, commands)
        Hako.logger.info "Started task: #{task.task_arn}"
        containers = wait_for_task(task)
        Hako.logger.info 'Oneshot task finished'
        exit_code = 127
        containers.each do |name, container|
          if container.exit_code.nil?
            Hako.logger.info "#{name} has stopped without exit_code: reason=#{container.reason}"
          else
            Hako.logger.info "#{name} has stopped with exit_code=#{container.exit_code}"
            if name == 'app'
              exit_code = container.exit_code
            end
          end
        end
        exit_code
      end

      def status
        service = describe_service
        unless service
          puts 'Unavailable'
          exit 1
        end

        unless service.load_balancers.empty?
          lb = service.load_balancers[0]
          lb_detail = @elb.describe_load_balancer
          puts 'Load balancer:'
          lb_detail.listener_descriptions.each do |ld|
            l = ld.listener
            puts "  #{lb_detail.dns_name}:#{l.load_balancer_port} -> #{lb.container_name}:#{lb.container_port}"
          end
        end

        puts 'Deployments:'
        service.deployments.each do |d|
          abbrev_task_definition = d.task_definition.slice(%r{task-definition/(.+)\z}, 1)
          puts "  [#{d.status}] #{abbrev_task_definition} desired_count=#{d.desired_count}, pending_count=#{d.pending_count}, running_count=#{d.running_count}"
        end

        puts 'Tasks:'
        @ecs.list_tasks(cluster: @cluster, service_name: service.service_arn).each do |page|
          unless page.task_arns.empty?
            tasks = @ecs.describe_tasks(cluster: @cluster, tasks: page.task_arns).tasks
            container_instances = {}
            @ecs.describe_container_instances(cluster: @cluster, container_instances: tasks.map(&:container_instance_arn)).container_instances.each do |ci|
              container_instances[ci.container_instance_arn] = ci
            end
            ec2_instances = {}
            @ec2.describe_instances(instance_ids: container_instances.values.map(&:ec2_instance_id)).reservations.each do |r|
              r.instances.each do |i|
                ec2_instances[i.instance_id] = i
              end
            end
            tasks.each do |task|
              ci = container_instances[task.container_instance_arn]
              instance = ec2_instances[ci.ec2_instance_id]
              print "  [#{task.last_status}]: #{ci.ec2_instance_id}"
              if instance
                name_tag = instance.tags.find { |t| t.key == 'Name' }
                if name_tag
                  print " (#{name_tag.value})"
                end
              end
              puts
            end
          end
        end

        puts 'Events:'
        service.events.first(10).each do |e|
          puts "  #{e.created_at}: #{e.message}"
        end
      end

      def remove
        service = describe_service
        if service
          @ecs.delete_service(cluster: @cluster, service: @app_id)
          Hako.logger.info "#{service.service_arn} is deleted"
        else
          puts "Service #{@app_id} doesn't exist"
        end

        @elb.destroy
      end

      private

      def describe_service
        service = @ecs.describe_services(cluster: @cluster, services: [@app_id]).services[0]
        if service && service.status != 'INACTIVE'
          service
        end
      end

      def determine_front_port
        if @dry_run
          return DEFAULT_FRONT_PORT
        end
        service = describe_service
        if service
          find_front_port(service)
        else
          new_front_port
        end
      end

      def new_front_port
        max_port = -1
        @ecs.list_services(cluster: @cluster).each do |page|
          unless page.service_arns.empty?
            @ecs.describe_services(cluster: @cluster, services: page.service_arns).services.each do |s|
              if s.status != 'INACTIVE'
                port = find_front_port(s)
                if port
                  max_port = [max_port, port].max
                end
              end
            end
          end
        end
        if max_port == -1
          DEFAULT_FRONT_PORT
        else
          max_port + 1
        end
      end

      def find_front_port(service)
        task_definition = @ecs.describe_task_definition(task_definition: service.task_definition).task_definition
        container_definitions = {}
        task_definition.container_definitions.each do |c|
          container_definitions[c.name] = c
        end
        if container_definitions['front']
          container_definitions['front'].port_mappings[0].host_port
        end
      end

      def task_definition_changed?(family, definitions)
        if @force
          return true
        end
        task_definition = @ecs.describe_task_definition(task_definition: family).task_definition
        container_definitions = {}
        task_definition.container_definitions.each do |c|
          container_definitions[c.name] = c
        end
        if definitions.any? { |definition| different_definition?(definition, container_definitions.delete(definition[:name])) }
          return true
        end
        !container_definitions.empty?
      rescue Aws::ECS::Errors::ClientException
        # Task definition does not exist
        true
      end

      def different_definition?(expected_container, actual_container)
        EcsDefinitionComparator.new(expected_container).different?(actual_container)
      end

      def register_task_definition(definitions)
        if task_definition_changed?(@app_id, definitions)
          @ecs.register_task_definition(
            family: @app_id,
            container_definitions: definitions,
          ).task_definition
        else
          :noop
        end
      end

      def create_definitions(containers, front_port)
        containers.map do |name, container|
          case name
          when 'front'
            front_container(container, front_port)
          else
            app_container(name, container)
          end
        end
      end

      def register_task_definition_for_oneshot(definitions)
        family = "#{@app_id}-oneshot"
        if task_definition_changed?(family, definitions)
          @ecs.register_task_definition(
            family: "#{@app_id}-oneshot",
            container_definitions: definitions,
          ).task_definition
        else
          :noop
        end
      end

      def front_container(front, front_port)
        environment = front.env.map { |k, v| { name: k, value: v } }
        {
          name: 'front',
          image: front.image_tag,
          cpu: front.cpu,
          memory: front.memory,
          links: front.links,
          port_mappings: [{ container_port: 80, host_port: front_port, protocol: 'tcp' }],
          essential: true,
          environment: environment,
          docker_labels: front.docker_labels,
        }
      end

      def app_container(name, app)
        environment = app.env.map { |k, v| { name: k, value: v } }
        {
          name: name,
          image: app.image_tag,
          cpu: app.cpu,
          memory: app.memory,
          links: app.links,
          port_mappings: [],
          essential: true,
          environment: environment,
          docker_labels: app.docker_labels,
        }
      end

      def run_task(task_definition, commands)
        @ecs.run_task(
          cluster: @cluster,
          task_definition: task_definition.task_definition_arn,
          overrides: {
            container_overrides: [
              {
                name: 'app',
                command: commands,
              },
            ],
          },
          count: 1,
          started_by: "hako oneshot #{@app_id}",
        ).tasks[0]
      end

      def wait_for_task(task)
        task_arn = task.task_arn
        container_instance_arn = nil
        started_at = nil
        loop do
          task = @ecs.describe_tasks(cluster: @cluster, tasks: [task_arn]).tasks[0]
          if container_instance_arn != task.container_instance_arn
            container_instance_arn = task.container_instance_arn
            report_container_instance(container_instance_arn)
          end
          unless started_at
            started_at = task.started_at
            if started_at
              Hako.logger.info "Started at #{started_at}"
            end
          end

          Hako.logger.debug "  status #{task.last_status}"

          if task.last_status == 'STOPPED'
            Hako.logger.info "Stopped at #{task.stopped_at}"
            containers = {}
            task.containers.each do |c|
              containers[c.name] = c
            end
            return containers
          end
          sleep 1
        end
      end

      def report_container_instance(container_instance_arn)
        container_instance = @ecs.describe_container_instances(cluster: @cluster, container_instances: [container_instance_arn]).container_instances[0]
        @ec2.describe_tags(filters: [{ name: 'resource-id', values: [container_instance.ec2_instance_id] }]).each do |page|
          tag = page.tags.find { |t| t.key == 'Name' }
          if tag
            Hako.logger.info "Container instance is #{container_instance_arn} (#{tag.value} #{container_instance.ec2_instance_id})"
          else
            Hako.logger.info "Container instance is #{container_instance_arn} (#{container_instance.ec2_instance_id})"
          end
        end
      end

      def create_or_update_service(task_definition_arn, front_port)
        service = describe_service
        if service.nil?
          params = {
            cluster: @cluster,
            service_name: @app_id,
            task_definition: task_definition_arn,
            desired_count: @desired_count,
            role: @role,
          }
          name = @elb.find_or_create_load_balancer(front_port)
          if name
            params[:load_balancers] = [
              {
                load_balancer_name: name,
                container_name: 'front',
                container_port: 80,
              },
            ]
          end
          @ecs.create_service(params).service
        else
          params = {
            cluster: @cluster,
            service: @app_id,
            desired_count: @desired_count,
            task_definition: task_definition_arn,
          }
          if service_changed?(service, params)
            @ecs.update_service(params).service
          else
            :noop
          end
        end
      end

      SERVICE_KEYS = %i[desired_count task_definition].freeze

      def service_changed?(service, params)
        SERVICE_KEYS.each do |key|
          if service.public_send(key) != params[key]
            return true
          end
        end
        false
      end

      def wait_for_ready(service)
        latest_event_id = find_latest_event_id(service.events)
        loop do
          s = @ecs.describe_services(cluster: service.cluster_arn, services: [service.service_arn]).services[0]
          s.events.each do |e|
            if e.id == latest_event_id
              break
            end
            Hako.logger.info "#{e.created_at}: #{e.message}"
          end
          latest_event_id = find_latest_event_id(s.events)
          finished = s.deployments.all? { |d| d.status != 'ACTIVE' }
          if finished
            return
          else
            sleep 1
          end
        end
      end

      def find_latest_event_id(events)
        if events.empty?
          nil
        else
          events[0].id
        end
      end
    end
  end
end
