// memtypes.c: print each Vulkan device's memory types and create a device on it. A check for the
// layer: `./build.sh test` runs it with and without VK_LAYER_VMLAB_coherent_memory.
#include <stdio.h>
#include <vulkan/vulkan.h>

int main(void) {
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) { puts("vkCreateInstance failed"); return 1; }
    VkPhysicalDevice pds[8]; uint32_t n = 8;
    vkEnumeratePhysicalDevices(inst, &n, pds);
    for (uint32_t d = 0; d < n; d++) {
        VkPhysicalDeviceProperties pr; vkGetPhysicalDeviceProperties(pds[d], &pr);
        VkPhysicalDeviceMemoryProperties2 m = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2};
        vkGetPhysicalDeviceMemoryProperties2(pds[d], &m);
        VkPhysicalDeviceMemoryProperties m1; vkGetPhysicalDeviceMemoryProperties(pds[d], &m1);
        printf("%s\n", pr.deviceName);
        for (uint32_t i = 0; i < m.memoryProperties.memoryTypeCount; i++) {
            VkMemoryPropertyFlags f = m.memoryProperties.memoryTypes[i].propertyFlags;
            printf("  type %u heap %u%s%s%s%s%s\n", i, m.memoryProperties.memoryTypes[i].heapIndex,
                   f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT ? " device-local" : "", f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ? " host-visible" : "",
                   f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT ? " coherent" : "", f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT ? " cached" : "",
                   f != m1.memoryTypes[i].propertyFlags ? "  (the two queries disagree)" : "");
        }
        float prio = 1; VkDevice dev;
        VkDeviceQueueCreateInfo q = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio};
        VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &q};
        VkResult r = vkCreateDevice(pds[d], &dci, NULL, &dev);
        printf("  vkCreateDevice: %d\n", r);
        if (r == VK_SUCCESS) {
            VkQueue queue; vkGetDeviceQueue(dev, 0, 0, &queue);
            printf("  vkDeviceWaitIdle: %d\n", vkDeviceWaitIdle(dev));
            vkDestroyDevice(dev, NULL);
        }
    }
    vkDestroyInstance(inst, NULL);
    return 0;
}
