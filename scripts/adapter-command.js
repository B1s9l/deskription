#!/usr/bin/env node
const fs=require("fs"),os=require("os"),path=require("path"),crypto=require("crypto");
const [identity,type,payloadText,operationArg]=process.argv.slice(2);
if(!identity||!type){console.error("usage: adapter-command.js INSTALLATION_ID TYPE [PAYLOAD_JSON] [OPERATION_ID]");process.exit(64)}
const requestID=crypto.randomUUID(),operationID=operationArg||crypto.randomUUID(),root=path.join(os.tmpdir(),"deskriptions-lab");
const command={type,protocolVersion:1,requestID,operationID,payload:payloadText?JSON.parse(payloadText):null};
fs.writeFileSync(path.join(root,`command-${identity}.json`),JSON.stringify(command));
const result=path.join(root,`result-${requestID}.json`),deadline=Date.now()+35000;
const timer=setInterval(()=>{if(fs.existsSync(result)){clearInterval(timer);const value=JSON.parse(fs.readFileSync(result,"utf8"));fs.unlinkSync(result);console.log(JSON.stringify(value,null,2));process.exit(["failed","indeterminate"].includes(value.status)?1:0)}if(Date.now()>deadline){clearInterval(timer);console.error("adapter command timed out");process.exit(3)}},100);
