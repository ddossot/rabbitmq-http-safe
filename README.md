<pre>
      ___                                   ___                  ___           ___           ___         ___     
     /__/\          ___         ___        /  /\                /  /\         /  /\         /  /\       /  /\    
     \  \:\        /  /\       /  /\      /  /::\              /  /:/_       /  /::\       /  /:/_     /  /:/_   
      \__\:\      /  /:/      /  /:/     /  /:/\:\            /  /:/ /\     /  /:/\:\     /  /:/ /\   /  /:/ /\  
  ___ /  /::\    /  /:/      /  /:/     /  /:/~/:/           /  /:/ /::\   /  /:/~/::\   /  /:/ /:/  /  /:/ /:/_ 
 /__/\  /:/\:\  /  /::\     /  /::\    /__/:/ /:/           /__/:/ /:/\:\ /__/:/ /:/\:\ /__/:/ /:/  /__/:/ /:/ /\
 \  \:\/:/__\/ /__/:/\:\   /__/:/\:\   \  \:\/:/            \  \:\/:/~/:/ \  \:\/:/__\/ \  \:\/:/   \  \:\/:/ /:/
  \  \::/      \__\/  \:\  \__\/  \:\   \  \::/              \  \::/ /:/   \  \::/       \  \::/     \  \::/ /:/ 
   \  \:\           \  \:\      \  \:\   \  \:\               \__\/ /:/     \  \:\        \  \:\      \  \:\/:/  
    \  \:\           \__\/       \__\/    \  \:\                /__/:/       \  \:\        \  \:\      \  \::/   
     \__\/                                 \__\/                \__\/         \__\/         \__\/       \__\/    
</pre>

RabbitMQ HTTP SAFE (Store And Forward Engine)
=============================================

A store-and-forward HTTP gateway plugin for RabbitMQ.

## Goal

To simplify the integration and communication of services over HTTP by relieving systems from the chore of resending requests when something went wrong with "the other side".

http-safe goes beyond the fire and forget paradigm as it supports the notion of delivery callback in order to inform the originating system of the success or failure of its dispatch request. 

> If you're running in the cloud and are OK using Amazon AWS, then consider using [SNS](http://aws.amazon.com/sns/) instead of http-safe :)

## Installation

In order to use the http-safe plugin, you need first to install the following plugins on RabbitMQ 2.3.1:

- [amqp_client](http://www.rabbitmq.com/releases/plugins/v2.3.1/amqp_client-2.3.1.ez)
- [mochiweb](http://www.rabbitmq.com/releases/plugins/v2.3.1/mochiweb-2.3.1.ez)
- [rabbitmq-mochiweb](http://www.rabbitmq.com/releases/plugins/v2.3.1/rabbitmq-mochiweb-2.3.1.ez)
- [ibrowse](https://github.com/downloads/ddossot/rabbitmq-ibrowse-wrapper/ibrowse-2.1.3-rmq0.0.0-git6ed0f3e.ez)

If you don't build the plugin from source, then get the latest one from the above download link.

## Configuration

Good news: there is nothing to configure in order to use http-safe.

If you're not happy with the port it's listening on, you'll need to configure the Mochiweb plugin as explained [here](http://hg.rabbitmq.com/rabbitmq-mochiweb/file/rabbitmq_v2_3_1/README).

## Usage

Using http-safe is very straightforward: you simply send it the HTTP request your intending to send to a server, using whatever verb you want, and just add a few control headers. http-safe will then try to send it to the intended recipient as fast as it can, retrying as much and as often as configured. In case of success or failure, it can optionally call you back.

http-safe then responds:

    204
    X-SAFE-Correlation-Id: <correlation_id>

This correlation ID header will be added to the dispatched HTTP request for traceability.

Here are the HTTP headers that you must/can include in your request to http-safe:

<table>
<tr><th>Header</th><th>Required?</th><th>Value</th></tr>
<tr><td>X-SAFE-Target-URI</td><td>Yes</td><td>The URI of the target server.</td></tr>
<tr><td>X-SAFE-Accept-Regex</td><td>Yes</td><td>A regular expression that must be matched by the status code replied by the target server.</td></tr>
<tr><td>X-SAFE-Max-Retries</td><td>No</td><td>Number of resend attempts to perform if the first dispatch failed. Default is 0.</td></tr>
<tr><td>X-SAFE-Retry-Interval</td><td>Yes if X-SAFE-Max-Retries &gt; 0</td><td>The number of minutes between two dispatch attempts. Must be &gt;0 and &lt;=60.</td></tr>
<tr><td>X-SAFE-Callback-URI</td><td>No</td><td>The URI of a server to call in case of successfull or aborted (ie. all attempts failed) dispatch.</td></tr>
<table>

In addition to the X-SAFE-Correlation-Id header shown above, http-safe can add the following headers when it calls you back:

- X-SAFE-Forward-Outcome: 'success' or 'failure',
- X-SAFE-Forward-Status: the status code replied by the target server.

## Limitations

* The maximum size of an HTTP entity that can be stored-and-forwarded is 1MB.

#### Copyright David Dossot - 2011 - MIT License
