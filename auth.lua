local auth = {
	CLIENT_ID = "65b708073fc0480ea92a077233ca87bd",
	SCOPES = "app-remote-control playlist-modify playlist-modify-private playlist-modify-public playlist-read "
		.. "playlist-read-collaborative playlist-read-private streaming ugc-image-upload user-follow-modify "
		.. "user-follow-read user-library-modify user-library-read user-modify user-modify-playback-state "
		.. "user-modify-private user-personalized user-read-currently-playing user-read-email user-read-play-history "
		.. "user-read-playback-position user-read-playback-state user-read-private user-read-recently-played user-top-read",
}

function auth.encode(text)
	return (tostring(text):gsub("[^%w%-_%.~]", function(char) return string.format("%%%02X", char:byte()) end))
end

function auth.form(fields)
	local parts = {}
	for key, value in pairs(fields) do
		table.insert(parts, key .. "=" .. auth.encode(value))
	end
	return table.concat(parts, "&")
end

function auth.decode(response)
	if not response or response.body == "" then
		return {}
	end
	local ok, data = pcall(nari.json_decode, response.body)
	return ok and type(data) == "table" and data or {}
end

function auth.save(body)
	nari.set("access", { token = body.access_token, expires = os.time() + (body.expires_in or 3600) }, { private = true })
	if body.refresh_token then
		nari.set("refresh_token", body.refresh_token, { private = true })
	end
end

function auth.cached()
	local access = nari.get("access")
	if access and access.expires > os.time() + 60 then
		return access.token
	end
end

function auth.token()
	local cached = auth.cached()
	if cached then
		return cached
	end
	local refresh = nari.get("refresh_token")
	if not refresh then
		return nil, "Not signed in to Spotify"
	end
	local response, problem = nari.http({
		method = "POST",
		url = "https://accounts.spotify.com/api/token",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = auth.form({ grant_type = "refresh_token", refresh_token = refresh, client_id = auth.CLIENT_ID }),
	})
	local body = auth.decode(response)
	if body.access_token then
		auth.save(body)
		return body.access_token
	end
	return auth.cached() or nil, problem or body.error_description or body.error or ("status " .. tostring(response and response.status))
end

return auth
