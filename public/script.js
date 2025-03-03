// 初始化页面，加载当前限速端口
window.onload = function () {
  getCurrentPorts();
};

// 添加端口
function addPort() {
  const ports = document.getElementById('addPort').value;
  if (ports) {
    fetch('/addPort?ports=' + ports)
    .then(response => response.text())
    .then(data => {
        document.getElementById('result').innerHTML = data;
        getCurrentPorts();
      })
    .catch(error => {
        document.getElementById('result').innerHTML = `请求出错：${error}`;
      });
  }
}

// 获取当前限速端口
function getCurrentPorts() {
  fetch('/getPorts')
  .then(response => response.text())
  .then(data => {
      const portList = document.getElementById('portList');
      portList.innerHTML = '';
      const portsArray = data.split(',');
      portsArray.forEach(port => {
        const li = document.createElement('li');
        li.textContent = port;
        portList.appendChild(li);
      });
    })
  .catch(error => {
      document.getElementById('result').innerHTML = `请求出错：${error}`;
    });
}

// 修改网速
function updateSpeed() {
  const totalBandwidth = document.getElementById('totalBandwidth').value;
  const rate = document.getElementById('rate').value;
  const ceil = document.getElementById('ceil').value;
  if (totalBandwidth && rate && ceil) {
    fetch(`/updateSpeed?totalBandwidth=${totalBandwidth}&rate=${rate}&ceil=${ceil}`)
    .then(response => response.text())
    .then(data => {
        document.getElementById('result').innerHTML = data;
      })
    .catch(error => {
        document.getElementById('result').innerHTML = `请求出错：${error}`;
      });
  }
}

// 清除所有限速端口
function clearAllPorts() {
  fetch('/clearAllPorts')
  .then(response => response.text())
  .then(data => {
      document.getElementById('result').innerHTML = data;
      getCurrentPorts();
    })
  .catch(error => {
      document.getElementById('result').innerHTML = `请求出错：${error}`;
    });
}

// 移除单个或多个限速端口
function removePorts() {
  const ports = document.getElementById('removePorts').value;
  if (ports) {
    fetch('/removePorts?ports=' + ports)
    .then(response => response.text())
    .then(data => {
        document.getElementById('result').innerHTML = data;
        getCurrentPorts();
      })
    .catch(error => {
        document.getElementById('result').innerHTML = `请求出错：${error}`;
      });
  }
}
