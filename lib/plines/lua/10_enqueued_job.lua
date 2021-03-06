local PlinesEnqueuedJob = {}
PlinesEnqueuedJob.__index = PlinesEnqueuedJob

function Plines.enqueued_job(pipeline_name, jid)
  local job = {}
  setmetatable(job, PlinesEnqueuedJob)

  job.pipeline_name = pipeline_name
  job.jid = jid
  job.key = "plines:" .. pipeline_name .. ":EnqueuedJob:" .. jid

  return job
end

function PlinesEnqueuedJob:expire(data_ttl_in_milliseconds)
  self:for_each_enqueued_job_sub_key(function(key)
    redis.call('pexpire', key, data_ttl_in_milliseconds)
  end)
end

function PlinesEnqueuedJob:delete()
  self:for_each_enqueued_job_sub_key(function(key)
    redis.call('del', key)
  end)
end

function PlinesEnqueuedJob:for_each_enqueued_job_sub_key(func)
  for _, sub_key in ipairs(plines_enqueued_job_sub_keys) do
    func(self.key .. ":" .. sub_key)
  end
end

function PlinesEnqueuedJob:external_dependencies()
  return redis.call('sunion',
    self:pending_external_dependencies_key(),
    self:resolved_external_dependencies_key(),
    self:timed_out_external_dependencies_key()
  )
end

function PlinesEnqueuedJob:pending_external_dependencies_key()
  return self.key .. ":pending_ext_deps"
end

function PlinesEnqueuedJob:resolved_external_dependencies_key()
  return self.key .. ":resolved_ext_deps"
end

function PlinesEnqueuedJob:timed_out_external_dependencies_key()
  return self.key .. ":timed_out_ext_deps"
end
