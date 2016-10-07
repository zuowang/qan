--[[
Copyright (c) 2014 Google Inc.

See LICENSE file for full terms of limited license.
]]

if not dqn then require "initenv" end
require 'config'
require 'functions'
--CNN setting
require 'xlua'
require 'optim'
require 'image'
local tnt = require 'torchnet'
local c = require 'trepl.colorize'
local json = require 'cjson'
-- for memory optimizations and graph generation
local optnet = require 'optnet'
local graphgen = require 'optnet.graphgen'
local iterm = require 'iterm'
require 'iterm.dot'
local total_reward
local nrewards
local nepisodes
local episode_reward

local opt = opt
--- General setup.
--local game_env, game_actions, agent, opt = setup(opt)
local game_actions, agent, opt = setup(opt)

local learn_start = agent.learn_start
local start_time = sys.clock()
local reward_counts = {}
local episode_counts = {}
local time_history = {}
local v_history = {}
local qmax_history = {}
local td_history = {}
local reward_history = {}
local step = 0
time_history[1] = 0

local usegpu = true

if take_action == 1 and add_momentum == 1 then
	tw = {}
	loadbaseweight(tw)
end
while episode < max_episode do
	--collectgarbage()
	--torch.manualSeed(0)
	episode = episode + 1
	local last_validation_loss = 10000
	local early_stop = false
	local min_epoch = 10
	local last_loss = nil
	local step_num = 0
	local log_sum = 0
	local cnnopt = {
		learningRate = 0.005,
		batchSize = 128
	}

	global_action = 1


	local function getIterator(mode)
		return tnt.ParallelDatasetIterator{
			nthread = 1,
			init    = function() require 'torchnet' end,
			closure = function()

				-- load MNIST dataset:
				local mnist = require 'mnist'
				local dataset = mnist[mode .. 'dataset']()

				dataset.data = dataset.data:reshape(dataset.data:size(1),
					dataset.data:size(2) * dataset.data:size(3)):double()
				-- return batches of data:
				return tnt.BatchDataset{
					batchsize = 128,
					dataset = tnt.ListDataset{  -- replace this by your own dataset
						list = torch.range(1, dataset.data:size(1)):long(),
						load = function(idx)
							return {
								input  = dataset.data[idx],
								target = torch.LongTensor{dataset.label[idx] + 1},
							}  -- sample contains input and target
						end,
					}
				}
			end,
		}
	end

	-- set up logistic regressor:

	local net = nn.Sequential()
	local Convolution = nn.SpatialConvolution
	local Max = nn.SpatialMaxPooling
	local Linear = nn.Linear
	local Tanh = nn.Tanh
	local Reshape = nn.Reshape
	net:add(Reshape(1,28,28))
	net:add(Convolution(1,20,5,5))
	net:add(nn.Tanh())
	net:add(Max(2,2,2,2))
	net:add(Convolution(20,50,5,5))
	net:add(nn.Tanh())
	net:add(Max(2,2,2,2))
	net:add(Reshape(50*4*4))
	net:add(Linear(50*4*4, 500))
	net:add(nn.Tanh())
	net:add(Linear(500, 10))

	--torch.save('weights/start_w5.t7', net:get(5).weight)

	--local net = torch.load('weights/net9.t7')
	for i=1,8 do
		if net:get(i).weight then
			print(net:get(i).weight:size())
		end
	end
	print(net)
	local criterion = nn.CrossEntropyCriterion()

	-- set up training engine:
	local engine = tnt.SGDEngine()
	local meter  = tnt.AverageValueMeter()
	local clerr  = tnt.ClassErrorMeter{topk = {1} }

	local argcheck = require 'argcheck'
	require('MiniBatch')

	engine.hooks.onStartEpoch = function(state)
		meter:reset()
		clerr:reset()
		minibatch:reset(cnnopt.batchSize)
	end
	engine.hooks.onForwardCriterion = function(state)
		meter:add(state.criterion.output)
		clerr:add(state.network.output, state.sample.target)
		if state.training then
			print(string.format('avg. loss: %2.4f; avg. error: %2.4f',
				meter:value(), clerr:value{k = 1}))
		end
	end

	-- set up GPU training:
	if usegpu then
		-- copy model to GPU:
		require 'cunn'
		net       = net:cuda()
		criterion = criterion:cuda()
		-- copy sample to GPU buffer:
		local igpu, tgpu = torch.CudaTensor(), torch.CudaTensor()
		engine.hooks.onSample = function(state)
			igpu:resize(state.sample.input:size() ):copy(state.sample.input)
			tgpu:resize(state.sample.target:size()):copy(state.sample.target)
			state.sample.input  = igpu
			state.sample.target = tgpu
		end  -- alternatively, this logic can be implemented via a TransformDataset
	end


	engine.hooks.onEndEpoch = function(state)
		local train_loss = meter:value()
		local train_err = clerr:value{k = 1}
		meter:reset()
		clerr:reset()
		curr_mode = 'testcnn'
		engine:test{
			network = net,
			iterator = getIterator('test'),
			criterion = criterion,
		}
		curr_mode = 'traincnn'

		local acc = 100 - clerr:value{k = 1}
		--local acc_str = string.format('%.6f\n', acc)
		--print('acc = ' .. acc_str)
		--output_file_writer:write(acc_str)
		--io.flush()
		os.execute('echo ' .. (100 - clerr:value{k = 1}) .. '>> ' .. output_file)
		if state.epoch == state.maxepoch then
			--output_file_writer:write('------\n')
			--lr_file_writer:write('------\n')
			os.execute('echo ------ >> ' .. output_file)
			os.execute('echo ------ >> ' .. lr_file)
		end
		if savebaselineweight == 1 then
			--torch.save('weights/w2.t7', net:get(2).weight)
			--torch.save('weights/w5.t7', net:get(5).weight)
			--torch.save('weights/'..episode..'_w9.t7', net:get(9).weight)
			torch.save('weights/end_w5.t7', net:get(5).weight)
			--torch.save('weights/net' .. state.epoch .. '.t7', net)
		end

	end

	function getReward(batch_loss)
		local reward = 0
		--TODO: should get current error
		if batch_loss then
			--[[--reward = 1 / math.abs(batch_loss - final_loss)
			if last_loss then
				log_sum = log_sum + math.log(batch_loss)-math.log(last_loss)
				assert(step_num >= 2, 'step_num should begin from 2 !')
				reward = -1/(step_num-1) * log_sum
			end
			last_loss = batch_loss]]
			reward = 1 / (batch_loss + 0.0000001)
		end
		if verbose then
			if batch_loss and reward then
				print ('batch_loss: ' .. batch_loss)
				print ('reward: '.. reward)
			end
		end
		return reward
	end

	function getState(batch_loss) --state is set in cnn.lua

		local s1 = net:get(2).weight --20*25 (20,1,5,5)
		local s2 = net:get(5).weight --25 (50,20,5,5)
		local s3 = net:get(9).weight --800*500
		--21*25 = 525
		--s1 = torch.mean(s1, 1):view(-1)
		--s2 = torch.mean(s2, 1):view(-1)
		--local tstate = torch.cat(s1, s2)
		s1 = s1:reshape(s1:size(1), s1:size(2), s1:size(3)*s1:size(4))
		s2 = s2:reshape(s2:size(1), s2:size(2), s2:size(3)*s2:size(4))

		function get_g_c(m)
			local r = m:reshape(m:nElement()) --m:view(-1)
			local r_sort = torch.sort(r)
			local n = r:nElement()
			local n1 = math.floor(n*0.25)
			local n2 = math.floor(n*0.5)
			local n3 = math.floor(n*0.75)-- quantiles(0.25, 0.5, 0.75)
			local g_c = torch.FloatTensor(12)
			g_c[1] = torch.mean(r)
			g_c[2] = r_sort[n1]
			g_c[3] = r_sort[n2]
			g_c[4] = r_sort[n3]
			g_c[5] = torch.std(r)
			g_c[6] = skewness(r)
			g_c[7] = kurtosis(r)
			g_c[8] = central_moment(r, 1)
			g_c[9] = central_moment(r, 2)
			g_c[10] = central_moment(r, 3)
			g_c[11] = central_moment(r, 4)
			g_c[12] = central_moment(r, 5)
			--local g_c_44 = torch.cat(g_c, k_bins_entropy(r))
			--return g_c_44
			--print(g_c)
			return g_c
		end
		function get_h_d(s_param, type)
			--g_c
			local s = torch.Tensor(20,1,25):copy(s_param)
			local row = s:size(1)
			local col = s:size(2)
			local size = row
			type = type or 0
			if type == 1 then
				size = row * col
				s = s:reshape(size, s:size(3))
			end
			local g = torch.FloatTensor(size, 12) -- 44 = 12 + 32
			for i = 1, size do
				local g_c = get_g_c(s[i])
				g[i] = g_c
			end
			g = g:transpose(1, 2)  -- 13 rows
			--h_c
			local h = torch.FloatTensor(12, 5)
			for i = 1, 12 do
				local h_d = torch.FloatTensor(5)
				h_d[1] = torch.mean(g[i])
				h_d[2] = torch.median(g[i])
				h_d[3] = torch.std(g[i])
				h_d[4] = torch.max(g[i])
				h_d[5] = torch.min(g[i])
				h[i] = h_d
			end
			return h
		end

		local res = {}
		res[#res+1] = get_g_c(s1):reshape(12)
		res[#res+1] = get_h_d(s1):reshape(60)
		res[#res+1] = get_h_d(s1:transpose(1,2)):reshape(60)
		res[#res+1] = get_h_d(s1, 1):reshape(60)

		--print(res[1])
		--print(res[2])
		--print(res[3])
		--print(res[4])

		--get one-hot coding of rouletee
		res[#res+1] = minibatch:getOneHot()  --10

		local state = res[1]
		for i = 2, #res do
			state = torch.cat(state, res[i])
		end
		-- first layer: 12 + 12*5 + 12*5 + 12*5 + 10 = 202

		local reward = getReward(batch_loss)
		if terminal == true then
			terminal = false
			return state, reward, true
		else
			return state, reward, false
		end
	end

	function step(state, batch_loss, action, tof)
		--take action from DQN, tune learning rate
		--TODO
		--[[
			action 1~10: class 1~10
		]]
		--FIXME: 保证每个 episode 开始 last_loss 都等于nil
		if DQN_mode == 'train' then
			step_num = step_num + 1
		end
		if verbose then
			print('action = ' .. action)
		end
		global_action = action
		return getState(batch_loss)
	end

	if take_action == 1 then
		--DQN init
		minibatch:reset(cnnopt.batchSize)
		screen, reward, terminal = getState(2.33)
		step_num = 1
	end

	local iteration_index = 0
	--will be called after each iteration
	engine.hooks.onForwardCriterion = function(state)
	    meter:add(state.criterion.output)
	    clerr:add(state.network.output, state.sample.target)
		if curr_mode == 'testcnn' then return end
		if take_action == 0 then return end

		local batch_loss = state.criterion.output
		iteration_index = iteration_index + 1
		if iteration_index < momentum_times and add_momentum == 1 then
			add_momentum_to_all_layer(net, tw)
		end
		--given state, take action
		if verbose then
			print('--------------------------------------------------------')
		end
		local action_index = 0
		if verbose then
			print('epoch = ' .. state.epoch)
		end
		if episode % dqn_test_interval > 0 then
			DQN_mode = 'train'
		    action_index = agent:perceive(reward, screen, terminal)
		else
			DQN_mode = 'test'
		    action_index = agent:perceive(reward, screen, terminal, true, 0.05)
		end
		if not terminal then
		   screen, reward, terminal = step(state, batch_loss, game_actions[action_index], true)
		else
		   screen, reward, terminal = getState(batch_loss)
		   reward = 0
		   terminal = false
		end
	end

	if take_action == 1 then
		engine.train = argcheck{
			{name="self", type="tnt.SGDEngine"},
			{name="network", type="nn.Module"},
			{name="criterion", type="nn.Criterion"},
			{name="lr", type="number"},
			{name="lrcriterion", type="number", defaulta="lr"},
			{name="maxepoch", type="number", default=1000},
			call =
			function(self, network, criterion, lr, lrcriterion, maxepoch)
				local state = {
					network = network,
					criterion = criterion,
					lr = lr,
					lrcriterion = lrcriterion,
					maxepoch = maxepoch,
					sample = {},
					epoch = 0, -- epoch done so far
					t = 0, -- samples seen so far
					training = true
				}
				self.hooks("onStart", state)
				while state.epoch < state.maxepoch do
					state.network:training()

					self.hooks("onStartEpoch", state)
					local mnist = require 'mnist'
					local dataset = mnist['traindataset']()
					dataset.data = dataset.data:reshape(dataset.data:size(1),
						dataset.data:size(2) * dataset.data:size(3)):double()

					--local simu_action = 10
					for i = 1, 468 do
					--for i = 1, 60000 do
						local batchindex = minibatch:step(global_action)
						--simu_action = simu_action - 1
						--if simu_action == 0 then simu_action = 10 end
						local bsize = minibatch.batchsize
						local sample = {
							target = torch.LongTensor(bsize),
							input = torch.ByteTensor(bsize, 784)
						}
						for j = 1, bsize do
							sample.input[j] = dataset.data[batchindex[j]]
							sample.target[j] = dataset.label[batchindex[j]] + 1 --大坑...这里要加1......
						end
						--input = dataset.data[idx]:float(),
						--target = torch.LongTensor{dataset.labels[idx]},

						state.sample = sample
						self.hooks("onSample", state)

						state.network:forward(sample.input)
						self.hooks("onForward", state)
						state.criterion:forward(state.network.output, sample.target)
						self.hooks("onForwardCriterion", state)

						state.network:zeroGradParameters()
						if state.criterion.zeroGradParameters then
							state.criterion:zeroGradParameters()
						end

						state.criterion:backward(state.network.output, sample.target)
						self.hooks("onBackwardCriterion", state)
						state.network:backward(sample.input, state.criterion.gradInput)
						self.hooks("onBackward", state)

						assert(state.lrcriterion >= 0, 'lrcriterion should be positive or zero')
						if state.lrcriterion > 0 and state.criterion.updateParameters then
							state.criterion:updateParameters(state.lrcriterion)
						end
						assert(state.lr >= 0, 'lr should be positive or zero')
						if state.lr > 0 then
							state.network:updateParameters(state.lr)
						end
						state.t = state.t + 1
						self.hooks("onUpdate", state)
					end
					state.epoch = state.epoch + 1
					self.hooks("onEndEpoch", state)
				end
				self.hooks("onEnd", state)
			end
		}
	end
	-- train the model:
	engine:train{
		network   = net,
		criterion = criterion,
		lr = cnnopt.learningRate,
		maxepoch = 10
		--optimMethod = optim.sgd,
		--config = tablex.deepcopy(cnnopt),
		--maxepoch = cnnopt.max_epoch,
	}

	if episode % dqn_test_interval == 0 then  --test
		local ave_q_max = 0
		ave_q_max = agent:getAveQ()
		print('ave_q_max = ' .. ave_q_max)
		if ave_q_max then
			--Q_file_writer:write(string.format('%f', ave_q_max) .. '\n')
			os.execute('echo ' .. ave_q_max .. ' >> ' .. Q_file)
		end
	end

end

io.close(output_file_writer)
io.close(Q_file_writer)
io.close(lr_file_writer)
io.close(rescale_reward_file_writer)
io.close(validation_output_file_writer)
io.close(minibatch.mapping_file_writer)