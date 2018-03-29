local cjson = require "cjson.safe"
local request = require "resty.jxwaf.request"
local transform = require "resty.jxwaf.transform"
local operator = require "resty.jxwaf.operator"
local resty_random = require "resty.random"
local str = require "resty.string"
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert
local table_sort = table.sort
local table_concat = table.concat
local http = require "resty.jxwaf.http"
local _M = {}
_M.version = "1.0"


local _config_path = "/opt/jxwaf/nginx/conf/jxwaf/jxwaf_config.json"
local _config_info = {}
local _rules = {}

local function _sort_rules(a,b)
        return tonumber(a.rule_id)<tonumber(b.rule_id)
end


local function _process_request(var,otp)
	local t = request.request[var.rule_var]()
	if type(t) ~= "string" and type(t) ~= "table" then
		ngx.log(ngx.ERR,"run fail,can not decode http args ",type(t).."   "..var.rule_var)
		ngx.log(ngx.ERR,ngx.req.raw_header())
		ngx.exit(500)
	end
	if type(t) == "string" then
		return t
	end
	
	local rule_var = var.rule_var

	if (rule_var == "ARGS" or rule_var == "ARGS_GET" or rule_var == "ARGS_POST" or rule_var == "REQUEST_COOKIES" or rule_var == "REQUEST_HEADERS" or rule_var == "RESP_HEADERS" ) then
		
	
		if( type(var.rule_specific) == "table" ) then
			local specific_result = {}
			for _,v in ipairs(var.rule_specific) do
				local specific = t[v]
				if specific ~= nil then
					
					specific_result[v] = specific
				end
			end
			
			
			return specific_result
		end
		
		if( type(var.rule_ignore) == "table" ) then
			local ignore_result = {}
			ignore_result = t
			for _,v in ipairs(var.rule_ignore) do
				ignore_result[string.lower(v)] = nil
			end
			
			return ignore_result
 
		
		end				
				
	end
	
	return t
end



function _M.process_request(var)

	return _process_request(var)
end



local function _process_transform(process_request,rule_transform,var)
        if type(process_request) ~= "string" and type(process_request) ~= "table" then
                ngx.log(ngx.ERR,"run fail,can not transfrom http args")
                ngx.exit(500)
        end

	if  type(rule_transform) ~= "table" then
                ngx.log(ngx.ERR,"run fail,can not decode config file,transfrom error")
                ngx.exit(500)
        end

	if type(process_request) == "string" then
		local string_result = process_request
		for _,v in ipairs(rule_transform) do
			string_result = transform.request[v](string_result)				
		end
		return 	string_result
	end

	local result = {}
	local rule_var = var.rule_var
	if (rule_var == "ARGS" or rule_var == "ARGS_GET" or rule_var == "ARGS_POST" or rule_var == "REQUEST_COOKIES" or rule_var == "REQUEST_HEADERS" or rule_var == "RESP_HEADERS") then
		for k,v in pairs(process_request) do
                        if type(v) == "table" then
				local _result_table = {}
                                for _,_v in ipairs(v) do
					local _result = _v
                                        for _,__v in ipairs(rule_transform) do
                                                _result = transform.request[__v](_result)
                                        end 
					if type(_result) == "string" then
						table_insert(_result_table,_result)
					end
                                end
				result[k] = _result_table

                        else
				local _result = v
                                for _,_v in ipairs(rule_transform) do
		
                                        _result = transform.request[_v](_result)
                                end
				if type(_result) == "string" then
					result[k] = _result
				end
                        end
                end
	else
		for _,v in ipairs(process_request) do
			local _result = v
			for _,_v in ipairs(rule_transform) do
		
				_result = transform.request[_v](_result)
			end

			if type(_result) == "string" then
				table_insert(result,_result)
			end
		end
	end

	return result 

end


local function _process_operator( process_transform , match , var , rule )
	local rule_operator = match.rule_operator
	local rule_pattern = match.rule_pattern
	local rule_negated = match.rule_negated
	local rule_var = var.rule_var
	if type(process_transform) ~= "string" and type(process_transform) ~= "table" then
		ngx.log(ngx.ERR,"run fail,can not operator http args")
                ngx.exit(500)
        end
	if type(rule_operator) ~= "string" and type(rule_pattern) ~= "string" then
		ngx.log(ngx.ERR,"rule_operator and rule_pattern error")
		ngx.exit(500)
	end
	
	if type(process_transform) == "string" then
		local result ,value,captures
		result,value,captures = operator.request[rule_operator](process_transform,rule_pattern)
		if rule_negated == "true" then
			result = not result
		end

		if result  then
			return result,value,rule_var,captures
		else
			return result
		end

	end
	
 
	if (rule_var == "ARGS" or rule_var == "ARGS_GET" or rule_var == "ARGS_POST" or rule_var == "REQUEST_COOKIES" or rule_var == "REQUEST_HEADERS" or rule_var == "RESP_HEADERS") then
		for k,v in pairs(process_transform) do
			if type(v) == "table" then
				for _,_v in ipairs(v) do
					local result,value,captures
					result,value,captures = operator.request[rule_operator](_v,rule_pattern)	
					if rule_negated == "true" then
						result = not result
					end
					if result  then
						return result,value,k,captures
					end
				end
			else
				local result,value,captures
				result,value,captures = operator.request[rule_operator](v,rule_pattern) 
                                if rule_negated == "true" then
                                	result = not result
                                end
			
                                if result  then
                                	return result,value,k,captures
                                end
			end
		end	
	
	else
		for _,v in ipairs(process_transform) do
			local result,value,captures
			result,value,captures = operator.request[rule_operator](v,rule_pattern)
			if rule_negated == "true" then
				result = not result
			end

			if result  then
				return result,value,rule_var,captures
			end


		end


	end


	return false

end



local function _rule_match(rules)
	local result
	ngx.ctx.rule_observ_log = {}
	for _,rule in ipairs(rules) do
		
	
			local matchs_result = true
			local ctx_rule_log = {}
			for _,match in ipairs(rule.rule_matchs) do
				local operator_result = false
			
				for _,var in ipairs(match.rule_vars) do
					local process_request = _process_request(var)
					local process_transform = _process_transform(process_request,match.rule_transform,var)
					local _operator_result,_operator_value,_operator_key,captures = _process_operator(process_transform,match,var,rule)
					
					if _operator_result and rule.rule_log == "true" then
                                                ctx_rule_log.rule_var = var.rule_var
                                                ctx_rule_log.rule_operator = match.rule_operator
                                                ctx_rule_log.rule_negated = match.rule_negated
                                                ctx_rule_log.rule_transform = match.rule_transform
						if not(rule.rule_action == "logic") then
                                        	        ctx_rule_log.rule_match_var = _operator_value
						
						end
						
                                                ctx_rule_log.rule_match_key = _operator_key
						ctx_rule_log.rule_url = ngx.var.request_uri
						ctx_rule_log.rule_remote_ip = ngx.var.remote_addr
						ctx_rule_log.rule_match_captures = captures

					end
		
                                	if  _operator_result then
						operator_result = _operator_result
						break
                                	end
				end	
		
				if (not operator_result) then
					matchs_result = false
					break
				end
				
			     end
                if matchs_result and rule.rule_log == "true" then                       
                    ctx_rule_log.rule_id = rule.rule_id
                    ctx_rule_log.rule_detail = rule.rule_detail
                    ctx_rule_log.rule_serverity = rule.rule_serverity
                    ctx_rule_log.rule_category = rule.rule_category
                    ctx_rule_log.rule_action = rule.rule_action
					if _config_info.log_all == "true" or rule.rule_log_all=="true" then
						ctx_rule_log.rule_raw_headers =  request.request['RAW_HEADER']()
						ctx_rule_log.rule_raw_post =  ngx.req.get_body_data()
					end
					ngx.ctx.rule_log = ctx_rule_log
				end
				if _config_info.observ_mode == "true" and matchs_result and rule.rule_log == "true" then
				
					if _config_info.observ_mode_white_ip == "false" then
						table_insert(ngx.ctx.rule_observ_log,ctx_rule_log)
						matchs_result = false
					else
						for _,v in ipairs(_config_info.observ_mode_white_ip) do
							local client_ip = ngx.var.remote_addr
							if client_ip == v then
								table_insert(ngx.ctx.rule_observ_log,ctx_rule_log)							
								matchs_result = false					
							end
				
						end
					end	
				end
	
                if rule.rule_action == "pass" and matchs_result then
					matchs_result = false
				end
		
			
			if matchs_result then
				return matchs_result,rule.rule_action
			end
		end

	 


	
	

	return result
end


function _M.rule_match(rules)

	return _rule_match(rules)

end


      

local function _base_update_rule()
	local _base_update_rule = {}
	local _update_website  =  _config_info.base_rule_update_website or "http://update.jxwaf.com/waf/update_rule"		
	local httpc = http.new()
	local api_key = _config_info.waf_api_key or "jxwaf"
      	local res, err = httpc:request_uri( _update_website , {
           method = "POST",
           body = "api_key="..api_key,
           headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
           }
      	})
	if not res then
        	ngx.log(ngx.ERR,"failed to request: ", err)
		return
      	end
	
	local read_body = res.body

	
	
		
	local _update_rule = cjson.decode(read_body)
	if _update_rule == nil or #_update_rule == 0 then
		ngx.log(ngx.ERR,"init fail,can not decode base rule config file")
	end
	for _,v in ipairs(_update_rule) do
		table_insert(_base_update_rule,v)
	end	
	table_sort(_base_update_rule,_sort_rules)
	_rules =  _base_update_rule
	ngx.log(ngx.ALERT,"success load base rule,count is "..#_rules)
		
	
	
	
end

local function _global_update_rule()
      
        local _update_website  =  _config_info.global_rule_update_website or "http://update.jxwaf.com/waf/update_global_rule"
        local httpc = http.new()
        local api_key = _config_info.waf_api_key or "jxwaf"
        local res, err = httpc:request_uri( _update_website , {
	
           method = "POST",
           body = "api_key="..api_key,
           headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
           }
        })
        if not res then
                ngx.log(ngx.ERR,"failed to request: ", err)
                return
        end
	local read_body = res.body
	
        local _update_rule = cjson.decode(read_body)
	
        if _update_rule == nil  then
               ngx.log(ngx.ERR,"init fail,can not decode remote global rule")
        end
	_config_info.base_engine = _config_info.base_engine or _update_rule['base_engine'] or "true"
	_config_info.log_all = _config_info.log_all or  _update_rule['log_all'] or "false"
	_config_info.log_remote = _config_info.log_remote or  _update_rule['log_remote'] or "false"
	_config_info.log_local = _config_info.log_local or  _update_rule['log_local'] or "true"
	_config_info.http_redirect = _config_info.http_redirect or  _update_rule['http_redirect'] or "/"
	_config_info.log_ip = _config_info.log_ip or  _update_rule['log_ip'] or "127.0.0.1"
	_config_info.log_port = _config_info.log_port or  _update_rule['log_port'] or "5555"
	_config_info.log_sock_type = _config_info.log_sock_type or  _update_rule['log_sock_type'] or "udp"
	_config_info.log_flush_limit = _config_info.log_flush_limit or  _update_rule['log_flush_limit'] or "1"
	_config_info.cookie_safe = _config_info.cookie_safe or _update_rule['cookie_safe'] or "true"
	_config_info.cookie_safe_client_ip = _config_info.cookie_safe_client_ip or _update_rule['cookie_safe_client_ip'] or "true"
	_config_info.cookie_safe_is_safe = _config_info.cookie_safe_is_safe or _update_rule['cookie_safe_is_safe'] or "false"	
	_config_info.aes_random_key = _config_info.aes_random_key or _update_rule['aes_random_key'] or  str.to_hex(resty_random.bytes(8))
	_config_info.observ_mode =  _config_info.observ_mode or _update_rule['observ_mode'] or "false"
	_config_info.observ_mode_white_ip =  _config_info.observ_mode_white_ip or _update_rule['observ_mode_white_ip'] or "false"
        ngx.log(ngx.ALERT,"success load global config ",_config_info.base_engine)
	if _config_info.base_engine == "true" then
		_base_update_rule()
	end
	
end



function _M.init_worker()
	local global_ok, global_err = ngx.timer.at(0,_global_update_rule)
	if not global_ok then
                ngx.log(ngx.ERR, "failed to create the global timer: ", global_err)
        end

end


function _M.init(config_path)
	local init_config_path = config_path or _config_path
	local read_config = assert(io.open(init_config_path,'r'))
	local raw_config_info = read_config:read('*all')
	read_config:close()
	local config_info = cjson.decode(raw_config_info)
	if config_info == nil then
		ngx.log(ngx.ERR,"init fail,can not decode config file")
	end

	_config_info = config_info


end


function _M.get_config_info()
	
	local config_info = _config_info

	return config_info

end


function _M.base_check()
	if _config_info.base_engine == "true" then
	local rules = _rules
	if  #rules == 0 then
		ngx.log(ngx.CRIT,"can not find rules")
		return
	--	ngx.exit(500)	
	end
	local result,rule_action = _rule_match(rules)	

	if( result and rule_action == 'deny' ) then
		ngx.exit(403)
	end	 
	if(result and rule_action == 'allow') then
		ngx.exit(0)
	end
	if(result and rule_action == "redirect") then
	
		ngx.redirect(_config_info.http_redirect)	
		
	end
	end
end


function _M.access_init()

	ngx.req.read_body()

end


return _M