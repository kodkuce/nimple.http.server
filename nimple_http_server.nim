import asynchttpserver, asyncdispatch
import sequtils, strutils, algorithm, parseutils
import os, tables, strtabs

let cdir = getCurrentDir()
var uAllowed = false;
var pnumber = 8000;


if paramCount()==0:
  echo ""
  echo "Running on Port:8000, uploading:disabled"
else:
  try:
    if paramCount()==1:
      if paramStr(1) == "-u":
        uAllowed = true;
      else:
        pnumber = parseInt(paramStr(1))

    if paramCount()==2:
      if paramStr(1) == "-u":
        uAllowed = true;
        pnumber = parseInt(paramStr(2))
      elif paramStr(2) == "-u":
        uAllowed = true;
        pnumber = parseInt(paramStr(1))
      else:
        raise newException(ValueError,"Write proper sytax")
  except:
    echo "Invalid syntax !"
    echo "nimple.http PORT optional -u for uploding enabled"
    echo "nimple.http 8000"
    echo "nimple.http 8000 -u"
    echo "nimple.http -u 8000"
    quit(0)
  echo ""
  echo "Running on " & $pnumber & " uploading:" & (if uAllowed: "enabled" else: "disabled")


var server = newAsyncHttpServer()

# STOLEN MULTPART FROM DOM96/JESTER :)

# Copyright (C) 2012 Dominik Picheta
# Permission is hereby granted, free of charge, to any person obtaining a copy of 
# this software and associated documentation files (the "Software"), to deal in 
# the Software without restriction, including without limitation the rights to 
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
# of the Software, and to permit persons to whom the Software is furnished to do 
# so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all 
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS 
# IN THE SOFTWARE.

type
  MultiData* = OrderedTable[string, tuple[fields: StringTableRef, body: string]]

template parseContentDisposition(): typed =
  var hCount = 0
  while hCount < hValue.len()-1:
    var key = ""
    hCount += hValue.parseUntil(key, {';', '='}, hCount)
    if hValue[hCount] == '=':
      var value = hvalue.captureBetween('"', start = hCount)
      hCount += value.len+2
      inc(hCount) # Skip ;
      hCount += hValue.skipWhitespace(hCount)
      if key == "name": name = value
      newPart[0][key] = value
    else:
      inc(hCount)
      hCount += hValue.skipWhitespace(hCount)

proc parseMultiPart*(body: string, boundary: string): MultiData =
  result = initOrderedTable[string, tuple[fields: StringTableRef, body: string]]()
  var mboundary = "--" & boundary

  var i = 0
  var partsLeft = true
  while partsLeft:
    var firstBoundary = body.skip(mboundary, i)
    if firstBoundary == 0:
      raise newException(ValueError, "Expected boundary. Got: " & body.substr(i, i+25))
    i += firstBoundary
    i += body.skipWhitespace(i)

    # Headers
    var newPart: tuple[fields: StringTableRef, body: string] = ({:}.newStringTable, "")
    var name = ""
    while true:
      if body[i] == '\c':
        inc(i, 2) # Skip \c\L
        break
      var hName = ""
      i += body.parseUntil(hName, ':', i)
      if body[i] != ':':
        raise newException(ValueError, "Expected : in headers.")
      inc(i) # Skip :
      i += body.skipWhitespace(i)
      var hValue = ""
      i += body.parseUntil(hValue, {'\c', '\L'}, i)
      if toLowerAscii(hName) == "content-disposition":
        parseContentDisposition()
      newPart[0][hName] = hValue
      i += body.skip("\c\L", i) # Skip *one* \c\L

    # Parse body.
    while true:
      if body[i] == '\c' and body[i+1] == '\L' and
         body.skip(mboundary, i+2) != 0:
        if body.skip("--", i+2+mboundary.len) != 0:
          partsLeft = false
          break
        break
      else:
        newPart[1].add(body[i])
      inc(i)
    i += body.skipWhitespace(i)

    result.add(name, newPart)

proc parseMPFD*(contentType: string, body: string): MultiData =
  var boundaryEqIndex = contentType.find("boundary=")+9
  var boundary = contentType.substr(boundaryEqIndex, contentType.len()-1)
  return parseMultiPart(body, boundary)

#THEFT CONCLUDED, NOW MY PART

proc listDir(input:string):string {.gcsafe.} =

  var paths = toSeq( (cdir&input).walkDir(true) )
  paths.sort() do (x,y:tuple[kind:PathComponent, path:string]) -> int:
              result = cmp( y.kind,  x.kind )
              if result == 0:
                result = cmp( x.path, y.path )

  var head = "<head> <style> .cl { margin-left:30px } </style> </head>"
  var upld = ""
  if uAllowed:
    upld = " <form action=\"/\" method=\"post\" enctype=\"multipart/form-data\" >" & 
    "<input type=\"hidden\" name=\"subdir\"" &
    " value=\"" & input & "\" >" &
    "<input type=\"file\" name=\"fname\">" &
    "<input type=\"submit\" value=\"Upload\"> </form>"

  var output = head & "<h3> Nim simple HTTP server </h3>" & upld & "<h5> Directory listing for " & input  & " </h5>"
  
  #adding back button if subdir
  if input != "/":
    var b:string = input
    b = b[0..rfind(b, "/")]
    if b.len > 1:
      b = b[0..b.high-1]
    output.add( "<div class=\"cl\"> <a href=\"" & b & "\">" & "../" & "</a> </div>" )

  if paths.len > 0: #if dir contains anything
    let sd = if input == "/" : "" else: "/"
    for c in paths:
      if c.kind == pcDir:
        output.add( "<div class=\"cl\"> <a href=" & input & sd & $c.path & """> &#128193 """ & $c.path &  "</a>  </div>" )
      else:
        output.add( "<div class=\"cl\"> <a href=" & input & sd & $c.path & """> &#128196 """ & $c.path &  "</a>  </div>" )
  
  return output


proc cb(req: Request) {.async, gcsafe.} =

  #for log
  echo "Recived: ",req.reqMethod, " ", req.url.path, " ", req.headers["host"], " ", req.headers["user-agent"]

  #GET REQUESTS
  if req.reqMethod==HttpGet and req.url.path.len > 3:
    if fileExists(cdir&req.url.path):
      let for_sending = readFile(cdir&req.url.path)
      await req.respond( Http200, for_sending)
    elif dirExists(cdir&req.url.path):
      await req.respond( Http200, listDir(req.url.path) )
    else:
      await req.respond(Http400, "<p> Invalid path </p>")
    return
  elif req.reqMethod==HttpGet and req.url.path=="/":
    await req.respond(Http200, listDir("/"))
  
  #POST FOR UPLOAD
  elif req.reqMethod==HttpPost:
    if uAllowed:
      try:
        var z = parseMPFD(req.headers["Content-Type"], req.body)

        if z["subdir"][1]!="/":
          z["subdir"][1]= z["subdir"][1] & "/"  

        #first we need check if file exists so we append (num) to it if have to
        var c:int = 0
        var fn:string = z["fname"][0]["filename"]
        while fileExists(cdir & z["subdir"][1] & fn):
          c.inc()
          var splited = splitFile( cdir & z["subdir"][1] & z["fname"][0]["filename"] )
          fn = splited[1] & "(" & $c & ")" & splited[2]

        writeFile(cdir & z["subdir"][1] & fn, z["fname"][1]) #TODO check

        await req.respond(Http200, "<p> File uploading finished, go </p> <a href=\"" & z["subdir"][1] & "\">BACK</a> ")
      except:
        let
          e = getCurrentException()
          msg = getCurrentExceptionMsg()
        echo "Got exception ", repr(e), " with message ", msg
        await req.respond(Http200, "<p> File uploading failed :( </p>" )
    else:
      await req.respond(Http400, "<p> Hmm run simpleserver with -u to enable upload </p>")
  else:
    await req.respond(Http400, "<p> Something wierd heppend :( </p>")

waitFor server.serve(Port(pnumber), cb)