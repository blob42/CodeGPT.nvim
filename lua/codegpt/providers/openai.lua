local curl = require("plenary.curl")
local Render = require("codegpt.template_render")
local Utils = require("codegpt.utils")
local Api = require("codegpt.api")
local Config = require("codegpt.config")

local M = {}

local function generate_messages(command, cmd_opts, command_args, text_selection)
	local system_message =
		Render.render(command, cmd_opts.system_message_template, command_args, text_selection, cmd_opts)
	local user_message = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)

	local messages = {}
	if system_message ~= nil and system_message ~= "" then
		table.insert(messages, { role = "system", content = system_message })
	end

	if user_message ~= nil and user_message ~= "" then
		table.insert(messages, { role = "user", content = user_message })
	end

	return messages
end

local function get_max_tokens(max_tokens, messages)
	local ok, total_length = Utils.get_accurate_tokens(vim.fn.json_encode(messages))

	if not ok then
		for _, message in ipairs(messages) do
			total_length = total_length + string.len(message.content)
			total_length = total_length + string.len(message.role)
		end
	end

	if total_length >= max_tokens then
		error("Total length of messages exceeds max_tokens: " .. total_length .. " > " .. max_tokens)
	end

	return max_tokens - total_length
end

function M.make_request(command, cmd_opts, command_args, text_selection)
	local messages = generate_messages(command, cmd_opts, command_args, text_selection)

	local max_tokens = cmd_opts.max_tokens
	if cmd_opts.max_output_tokens ~= nil then
		Utils.fail_if_exceed_context_window(cmd_opts.max_tokens, messages)
		max_tokens = cmd_opts.max_output_tokens
	else
		max_tokens = get_max_tokens(cmd_opts.max_tokens, messages)
	end

	local request = {
		temperature = cmd_opts.temperature,
		n = cmd_opts.number_of_choices,
		model = cmd_opts.model,
		messages = messages,
		max_tokens = max_tokens,
	}

	request = vim.tbl_extend("force", request, cmd_opts.extra_params)
	return request
end

local function curl_callback(response, cb)
	local status = response.status
	local body = response.body
	if status ~= 200 then
		body = body:gsub("%s+", " ")
		print("Error: " .. status .. " " .. body)
		return
	end

	if body == nil or body == "" then
		print("Error: No body")
		return
	end

	vim.schedule_wrap(function(msg)
		local json = vim.fn.json_decode(msg)
		M.handle_response(json, cb)
	end)(body)

	Api.run_finished_hook()
end

function M.make_headers()
	local token = vim.g["codegpt_openai_api_key"]
	if not token then
		error(
			"OpenAIApi Key not found, set in vim with 'codegpt_openai_api_key' or as the env variable 'OPENAI_API_KEY'"
		)
	end

	return { Content_Type = "application/json", Authorization = "Bearer " .. token }
end

function M.handle_response(json, cb)
	if json == nil then
		print("Response empty")
	elseif json.error then
		print("Error: " .. json.error.message)
	elseif not json.choices or 0 == #json.choices or not json.choices[1].message then
		print("Error: " .. vim.fn.json_encode(json))
	else
		local response_text = json.choices[1].message.content

		if response_text ~= nil then
			if type(response_text) ~= "string" or response_text == "" then
				print("Error: No response text " .. type(response_text))
			else
				local bufnr = vim.api.nvim_get_current_buf()
				if Config.opts.clear_visual_selection then
					vim.api.nvim_buf_set_mark(bufnr, "<", 0, 0, {})
					vim.api.nvim_buf_set_mark(bufnr, ">", 0, 0, {})
				end
				cb(Utils.parse_lines(response_text))
			end
		else
			print("Error: No message")
		end
	end
end

function M.make_call(payload, cb)
	local payload_str = vim.fn.json_encode(payload)
	local url = Config.opts.connection.chat_completions_url
	local headers = M.make_headers()
	Api.run_started_hook()
	curl.post(url, {
		body = payload_str,
		headers = headers,
		callback = function(response)
			curl_callback(response, cb)
		end,
		on_error = function(err)
			vim.defer_fn(function()
				vim.notify("curl error: " .. err.message, vim.log.levels.ERROR)
			end, 0)
			Api.run_finished_hook()
		end,
	})
end

function M.get_models()
	vim.notify("not implemented", vim.log.levels.WARN)
end

return M
