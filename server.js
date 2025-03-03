const express = require('express');
const { exec } = require('child_process');
const app = express();
const port = 3000;

// 静态文件服务，用于提供前端文件
app.use(express.static('public'));

// 添加端口
app.get('/addPort', (req, res) => {
  const ports = req.query.ports;
  const totalBandwidth = 1000;
  const rate = 100;
  const ceil = 200;
  exec(`./Throttle.sh 1 ${ports} ${totalBandwidth} ${rate} ${ceil}`, (error, stdout, stderr) => {
    if (error) {
      console.error(`执行出错: ${error}`);
      res.status(500).send('添加端口失败');
    } else {
      res.send('添加端口成功');
    }
  });
});

// 获取当前端口列表
app.get('/getPorts', (req, res) => {
  exec('./Throttle.sh 3', (error, stdout, stderr) => {
    if (error) {
      console.error(`执行出错: ${error}`);
      res.status(500).send('获取端口列表失败');
    } else {
      const portList = stdout.match(/限速端口:([\d,]+)/);
      if (portList) {
        res.send(portList[1]);
      } else {
        res.send('');
      }
    }
  });
});

// 修改网速
app.get('/updateSpeed', (req, res) => {
  const totalBandwidth = req.query.totalBandwidth;
  const rate = req.query.rate;
  const ceil = req.query.ceil;
  const ports = '80,443,22'; // 这里可根据实际情况修改
  exec(`./Throttle.sh 1 ${ports} ${totalBandwidth} ${rate} ${ceil}`, (error, stdout, stderr) => {
    if (error) {
      console.error(`执行出错: ${error}`);
      res.status(500).send('修改网速失败');
    } else {
      res.send('修改网速成功');
    }
  });
});

// 清除所有限速端口
app.get('/clearAllPorts', (req, res) => {
  exec('./Throttle.sh 2 1', (error, stdout, stderr) => {
    if (error) {
      console.error(`执行出错: ${error}`);
      res.status(500).send('清除所有端口失败');
    } else {
      res.send('清除所有端口成功');
    }
  });
});

// 移除指定端口
app.get('/removePorts', (req, res) => {
  const ports = req.query.ports;
  exec(`./Throttle.sh 2 2 ${ports}`, (error, stdout, stderr) => {
    if (error) {
      console.error(`执行出错: ${error}`);
      res.status(500).send('移除端口失败');
    } else {
      res.send('移除端口成功');
    }
  });
});

app.listen(port, () => {
  console.log(`服务器运行在 http://localhost:${port}`);
});
