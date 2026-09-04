# Runbook v2 SOP: R1Mk3 博物馆 world 遥控仿真

更新时间: 2026-06-12

适用主机: `maxw-5080`

目标: 进入或复现 `Gazebo Harmonic + R1Mk3 + baseControl2 + yarpmobilebasegui` 状态,在 TurboVNC `:21` 里用遥控器面板控制 R1 在 `SIM_MADAMA/madama_clock.world` 运动。

## 0. 当前已知状态

当前真正承载博物馆 world 和 R1 遥控链路的容器是:

```bash
docker_sim_compose-sim-run-42dee03cf3f4
```

这个容器的来源不是标准交互入口。它是一次 GPU/GL/EGL 测试命令启动出来的 `docker compose run --rm --entrypoint bash sim -c ...` 临时容器,但因为测试脚本卡在读取 `/dev/dri/card0`,容器没有退出。之后仿真进程被 `docker exec` 启动到了这个仍然存活的容器里。

同一时间还存在另一个容器:

```bash
docker_sim_compose-sim-run-3ee7fecd80ab
```

它更像正常入口容器: entrypoint 是 `/home/user1/.entrypoint.sh`,命令是 `terminator || bash`,并且承载了 `yarpserver --write` 和 `yarprun --server /console --log`。由于 compose 使用 `network_mode: host` 和 `pid: host`,两个容器内都能看到同一组宿主进程和同一个 YARP name server,不要只用 `ps` 或 `yarp name list` 判断进程归属。判断容器归属优先用:

```bash
docker top <container>
docker inspect --format '{{.Name}} PIDMode={{.HostConfig.PidMode}} NetworkMode={{.HostConfig.NetworkMode}} CMD={{json .Config.Cmd}} ENTRYPOINT={{json .Config.Entrypoint}}' <container>
```

## 1. 当前状态是怎么一步步到达的

在宿主机 `maxw-5080` 上,工作目录是:

```bash
cd /home/maxw/4sim/gh-ref/tour-guide-robot/tour-guide-robot/docker_stuff/docker_sim_compose
```

### 1.1 先启动了正常交互容器

正常入口大致是:

```bash
docker compose run --rm sim
```

该命令基于 `compose.yaml` 的 `sim` 服务启动容器,默认命令是:

```bash
bash -lc 'command -v terminator >/dev/null 2>&1 && terminator || bash'
```

当前对应容器:

```bash
docker_sim_compose-sim-run-3ee7fecd80ab
```

它启动了基础 YARP 服务:

```text
yarpserver --write
yarprun --server /console --log
```

### 1.2 又启动了一次 GPU/GL/EGL 测试容器

随后在同一 compose 目录执行过类似命令:

```bash
docker compose run --rm --entrypoint bash sim -c '
echo "=== id ==="
id

echo "=== nvidia-smi ==="
nvidia-smi -L 2>&1

echo "=== glxinfo ==="
glxinfo 2>&1 | grep -E "OpenGL renderer|OpenGL version" || echo "glxinfo FAILED"

echo "=== /dev/dri access test ==="
cat /dev/dri/card0 >/dev/null 2>&1 && echo "card0 readable" || stat -c "%a %G" /dev/dri/card0

echo "=== EGL test ==="
eglinfo 2>&1 | grep -i "EGL client" | head -3 || echo "eglinfo not available"
'
```

当前对应容器:

```bash
docker_sim_compose-sim-run-42dee03cf3f4
```

这本来只是测试容器,但进程停在:

```text
cat /dev/dri/card0
```

所以容器一直存活。

### 1.3 在测试容器里启动了 Gazebo world

之后有人通过 `docker exec` 在 `42dee...` 里启动了 Gazebo:

```bash
docker exec -d docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'GZ_SIM_RESOURCE_PATH="${GZ_SIM_RESOURCE_PATH}:/usr/local/src/robot/cer-sim/gazebo" \
__GLX_VENDOR_LIBRARY_NAME=mesa \
gz sim -r /usr/local/src/robot/tour-guide-robot/app/maps/SIM_MADAMA/madama_clock.world \
> /tmp/r1_gz_sim.log 2>&1'
```

当前能看到的进程形态:

```text
gz sim -r /usr/local/src/robot/tour-guide-robot/app/maps/SIM_MADAMA/madama_clock.world
gz sim server
gz sim gui
```

这里强制 `__GLX_VENDOR_LIBRARY_NAME=mesa` 是为了让 Gazebo GUI 在 TurboVNC `:21` 上创建 OpenGL 上下文。

### 1.4 在同一个测试容器里启动了底盘遥控链路

约 40 秒后又执行了:

```bash
docker exec -d docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'/home/user1/drive_up.sh > /tmp/r1_drive_up.log 2>&1'
```

`drive_up.sh` 做了这些事:

1. `yarp clean --timeout 0.5`,清理 stale YARP 注册。
2. 等待 `/r1mk3Sim/mobile_base/command:i` 出现,并用 `yarp ping /r1mk3Sim/mobile_base/rpc:i` 确认可连接。
3. 生成 `/tmp/baseControl2_r1mk3Sim_noROS.ini`。
4. 启动:

```bash
baseControl2 --from /tmp/baseControl2_r1mk3Sim_noROS.ini --skip_robot_interface_check
```

5. 发送:

```bash
echo 'run' | yarp rpc /baseControl/rpc
```

6. 启动:

```bash
yarpmobilebasegui
```

7. 连接 GUI 到 baseControl2:

```bash
yarp disconnect /yarpmobilebasegui:o /r1mk3Sim/mobile_base/command:i
yarp connect /yarpmobilebasegui:o /baseControl/input/joystick/data:i
```

最终控制链路是:

```text
yarpmobilebasegui:o
  -> /baseControl/input/joystick/data:i
  -> baseControl2
  -> /baseControl/command:o
  -> /r1mk3Sim/mobile_base/command:i
```

## 2. 退出 shell 后,重新进入当前可遥控状态

这条流程不重启仿真,只重新进入当前已运行状态。

### 2.1 从局域网电脑登录主机

```bash
ssh maxw-5080
```

### 2.2 确认当前关键容器还在

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep docker_sim_compose-sim-run
```

优先确认 `42dee...`:

```bash
docker top docker_sim_compose-sim-run-42dee03cf3f4 -eo pid,ppid,etime,cmd
```

应看到:

```text
gz sim -r .../SIM_MADAMA/madama_clock.world
baseControl2 --from /tmp/baseControl2_r1mk3Sim_noROS.ini --skip_robot_interface_check
yarpmobilebasegui
```

### 2.3 进入当前仿真容器

```bash
docker exec -it docker_sim_compose-sim-run-42dee03cf3f4 bash
```

进入后可用这些命令确认链路:

```bash
yarp ping /r1mk3Sim/mobile_base/rpc:i
yarp ping /baseControl/rpc
yarp name query /yarpmobilebasegui:o
yarp name query /baseControl/input/joystick/data:i
```

### 2.4 打开/连接 TurboVNC 桌面

在 VNC 客户端连接 `maxw-5080` 的 TurboVNC `:21`。进入桌面后应能看到:

```text
Gazebo Sim
yarpMobilebaseGUI
```

如果窗口被遮挡或最小化,在宿主机查窗口:

```bash
DISPLAY=:21 xdotool search --onlyvisible --name Gazebo
DISPLAY=:21 xdotool search --onlyvisible --name yarpMobilebaseGUI
```

操作 `yarpMobilebaseGUI` 的圆形摇杆即可控制 R1。

## 3. 当前状态失效时的就地修复

### 3.1 Gazebo 还在,但遥控 GUI 或 baseControl2 不在

先确认 Gazebo 端口可连接:

```bash
docker exec docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'yarp ping /r1mk3Sim/mobile_base/rpc:i'
```

如果可连接,重新启动底盘遥控链路:

```bash
docker exec -d docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'/home/user1/drive_up.sh > /tmp/r1_drive_up.log 2>&1'
```

查看日志:

```bash
docker exec docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'tail -120 /tmp/r1_drive_up.log'
```

### 3.2 GUI 存在但机器人不动

检查连接:

```bash
docker exec docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'yarp name query /yarpmobilebasegui:o; yarp name query /baseControl/input/joystick/data:i; yarp name query /baseControl/command:o'
```

重新连接:

```bash
docker exec docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'yarp disconnect /yarpmobilebasegui:o /r1mk3Sim/mobile_base/command:i >/dev/null 2>&1 || true
yarp connect /yarpmobilebasegui:o /baseControl/input/joystick/data:i
echo run | yarp rpc /baseControl/rpc'
```

### 3.3 YARP name server 有脏注册

```bash
docker exec docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'yarp clean --timeout 0.5'
```

清理后如果 `/baseControl/*` 端口消失,重新跑:

```bash
docker exec -d docker_sim_compose-sim-run-42dee03cf3f4 bash -lc \
'/home/user1/drive_up.sh > /tmp/r1_drive_up.log 2>&1'
```

## 4. 干净重启复现 SOP

这条流程用于当前容器已经不可用,或者需要从零复现。

### 4.1 登录并进入 compose 目录

```bash
ssh maxw-5080
cd /home/maxw/4sim/gh-ref/tour-guide-robot/tour-guide-robot/docker_stuff/docker_sim_compose
```

### 4.2 启动正常交互容器

```bash
docker compose run --rm sim
```

如果需要指定显示,确认环境或显式设置:

```bash
DISPLAY=:21 docker compose run --rm sim
```

### 4.3 在容器内启动仿真

推荐直接用脚本:

```bash
/home/user1/sim_up.sh
```

注意: `sim_up.sh` 最后会 `exec yarpmanager`,因此这个终端会被前台占用。

如果只想复现当前这次的最小运行状态,可在容器内手动启动 Gazebo:

```bash
GZ_SIM_RESOURCE_PATH="${GZ_SIM_RESOURCE_PATH}:/usr/local/src/robot/cer-sim/gazebo" \
__GLX_VENDOR_LIBRARY_NAME=mesa \
gz sim -r /usr/local/src/robot/tour-guide-robot/app/maps/SIM_MADAMA/madama_clock.world \
> /tmp/r1_gz_sim.log 2>&1 &
```

### 4.4 另开宿主机终端,启动遥控链路

```bash
ssh maxw-5080
docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | grep docker_sim_compose-sim-run
```

选正在跑 Gazebo 的容器,然后执行:

```bash
docker exec -d <container> bash -lc '/home/user1/drive_up.sh > /tmp/r1_drive_up.log 2>&1'
```

查看结果:

```bash
docker exec <container> bash -lc 'tail -120 /tmp/r1_drive_up.log'
```

成功时日志应包含:

```text
[drive_up] 激活电机 (run)...
[drive_up] 启动 yarpmobilebasegui...
[drive_up] 连接 GUI -> baseControl2...
[drive_up] 就绪! 在 VNC 桌面拖动摇杆即可控制底盘。
```

### 4.5 验证可遥控

```bash
docker exec <container> bash -lc '
yarp ping /r1mk3Sim/mobile_base/rpc:i &&
yarp ping /baseControl/rpc &&
yarp name query /yarpmobilebasegui:o &&
yarp name query /baseControl/input/joystick/data:i
'
```

在 TurboVNC `:21` 桌面中拖动 `yarpMobilebaseGUI` 摇杆,R1 应在 `Gazebo Sim` 的 `madama_clock.world` 中运动。

## 5. 停止当前仿真

只在确认无人使用时执行。

优先停止当前承载仿真的容器:

```bash
docker stop docker_sim_compose-sim-run-42dee03cf3f4
```

如果是干净重启流程启动的容器,替换为实际 `<container>`:

```bash
docker stop <container>
```

停止后建议清理 YARP stale 注册:

```bash
docker exec docker_sim_compose-sim-run-3ee7fecd80ab bash -lc 'yarp clean --timeout 0.5' || true
```

## 6. 快速判断表

```text
需要继续当前正在跑的博物馆仿真:
  进入 docker_sim_compose-sim-run-42dee03cf3f4

需要找正常交互入口:
  看 docker_sim_compose-sim-run-3ee7fecd80ab 或重新 docker compose run --rm sim

Gazebo 在,GUI/baseControl2 不在:
  对正在跑 Gazebo 的容器重新执行 /home/user1/drive_up.sh

GUI 能动但 R1 不动:
  确认 /yarpmobilebasegui:o 连接到 /baseControl/input/joystick/data:i,
  不是直接连接到 /r1mk3Sim/mobile_base/command:i
```
